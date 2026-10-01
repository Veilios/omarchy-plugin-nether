#!/usr/bin/env python3
"""
Tests for nether_vault.py.

The point of this suite is the symlink cases. A vault can be a clone, a synced
folder, or something shared with you, so a note name may already be occupied by
a symlink pointing anywhere on the filesystem. Path-based tools follow that
link; these tests assert that the vault helper refuses instead, and that the
file on the other side of the link is byte-for-byte unchanged afterwards.

Every op is checked against both attacks — a symlink at the destination and a
symlinked intermediate folder — and every op also has a happy-path case, so a
suite that simply refused everything would fail.

Run: python3 tests/test_vault_ops.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HELPER = os.path.join(REPO, "nether_vault.py")

PASSED = []
FAILED = []


def check(name, fn):
    try:
        fn()
        PASSED.append(name)
    except AssertionError as exc:
        FAILED.append((name, str(exc)))
    except Exception as exc:  # noqa: BLE001 - a crashing test is a failing test
        FAILED.append((name, "%s: %s" % (type(exc).__name__, exc)))


def run(op, vault, *rels, stdin=b""):
    return subprocess.run(
        [sys.executable, HELPER, op, vault, *rels],
        input=stdin,
        capture_output=True,
    )


class Env:
    """A vault, a file outside it, and a symlink at the destination."""

    def __init__(self, dest_link=True, intermediate_link=True):
        self.tmp = tempfile.mkdtemp(prefix="nether-vault-test.")
        self.vault = os.path.join(self.tmp, "vault")
        self.outside = os.path.join(self.tmp, "outside")
        os.makedirs(self.vault)
        os.makedirs(self.outside)

        self.secret = os.path.join(self.outside, "secret.txt")
        self.secret_body = b"do not touch me\n"
        with open(self.secret, "wb") as fp:
            fp.write(self.secret_body)

        # A normal note, so ops that act on an existing file have one.
        self.existing = os.path.join(self.vault, "existing.md")
        with open(self.existing, "wb") as fp:
            fp.write(b"# existing\n")

        # Attack 1: the destination is a symlink out of the vault.
        self.dest_link = os.path.join(self.vault, "note.md")
        if dest_link:
            os.symlink(self.secret, self.dest_link)

        # Attack 2: an intermediate folder is a symlink out of the vault.
        self.linkdir = os.path.join(self.vault, "linkdir")
        if intermediate_link:
            os.symlink(self.outside, self.linkdir)

        # An innocent symlink inside the vault, which must keep working.
        self.inner = os.path.join(self.vault, "real")
        os.makedirs(self.inner)
        self.inner_note = os.path.join(self.inner, "inner.md")
        with open(self.inner_note, "wb") as fp:
            fp.write(b"# inner\n")

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def secret_intact(self):
        with open(self.secret, "rb") as fp:
            return fp.read() == self.secret_body

    def nothing_escaped(self):
        """No new files may appear in the directory outside the vault."""
        return sorted(os.listdir(self.outside)) == ["secret.txt"]


# --------------------------------------------------------------------- create


def test_create_refuses_symlinked_destination():
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("create", env.vault, "note.md", stdin=b"attacker controlled\n")
        assert r.returncode != 0, "create followed the symlink and succeeded"
        assert env.secret_intact(), "the file behind the symlink was modified"
        assert b"attacker" not in open(env.secret, "rb").read()
    finally:
        env.close()


def test_create_refuses_symlinked_intermediate():
    env = Env(dest_link=False, intermediate_link=True)
    try:
        r = run("create", env.vault, "linkdir/note.md", stdin=b"escaped\n")
        assert r.returncode != 0, "create descended through a symlinked folder"
        assert env.nothing_escaped(), "a file was created outside the vault"
    finally:
        env.close()


def test_create_refuses_existing_file():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("create", env.vault, "existing.md", stdin=b"clobbered\n")
        assert r.returncode != 0, "create overwrote an existing note"
        assert open(env.existing, "rb").read() == b"# existing\n"
    finally:
        env.close()


def test_create_makes_a_real_note():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("create", env.vault, "fresh.md", stdin=b"# fresh\n")
        assert r.returncode == 0, "create failed on a clean path: %r" % r.stderr
        path = os.path.join(env.vault, "fresh.md")
        assert os.path.isfile(path) and not os.path.islink(path)
        assert open(path, "rb").read() == b"# fresh\n"
    finally:
        env.close()


def test_create_makes_missing_folders():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("create", env.vault, "a/b/c/deep.md", stdin=b"deep\n")
        assert r.returncode == 0, "create failed to make folders: %r" % r.stderr
        assert os.path.isfile(os.path.join(env.vault, "a/b/c/deep.md"))
    finally:
        env.close()


# ---------------------------------------------------------------------- write


def test_write_refuses_symlinked_destination():
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("write", env.vault, "note.md", stdin=b"clobbered\n")
        assert r.returncode != 0, "write followed the symlink"
        assert env.secret_intact(), "the file behind the symlink was modified"
    finally:
        env.close()


def test_write_refuses_symlinked_intermediate():
    env = Env(dest_link=False, intermediate_link=True)
    try:
        r = run("write", env.vault, "linkdir/note.md", stdin=b"escaped\n")
        assert r.returncode != 0, "write descended through a symlinked folder"
        assert env.nothing_escaped()
    finally:
        env.close()


def test_write_updates_a_real_note():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("write", env.vault, "existing.md", stdin=b"# updated\n")
        assert r.returncode == 0, "write failed on a real note: %r" % r.stderr
        assert open(env.existing, "rb").read() == b"# updated\n"
    finally:
        env.close()


def test_write_refuses_missing_note():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("write", env.vault, "absent.md", stdin=b"x\n")
        assert r.returncode != 0, "write invented a note"
    finally:
        env.close()


# ----------------------------------------------------------------------- move


def test_move_refuses_symlinked_destination():
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("move", env.vault, "existing.md", "note.md")
        # rename(2) would replace the symlink and leave its target alone, so
        # this is not a containment failure -- but it would destroy the link
        # invisibly, since find -type f never listed it. Refuse instead.
        assert r.returncode != 0, "move silently replaced a symlink"
        assert env.secret_intact(), "the file behind the symlink was modified"
        assert os.path.islink(env.dest_link), "the symlink was destroyed"
        assert os.path.isfile(env.existing), "the source note disappeared"
    finally:
        env.close()


def test_move_refuses_existing_destination():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        with open(os.path.join(env.vault, "other.md"), "wb") as fp:
            fp.write(b"# other\n")
        r = run("move", env.vault, "existing.md", "other.md")
        assert r.returncode != 0, "move clobbered an existing note"
        assert open(os.path.join(env.vault, "other.md"), "rb").read() == b"# other\n"
        assert os.path.isfile(env.existing), "the source note disappeared"
    finally:
        env.close()


def test_move_refuses_symlinked_intermediate():
    env = Env(dest_link=False, intermediate_link=True)
    try:
        r = run("move", env.vault, "existing.md", "linkdir/moved.md")
        assert r.returncode != 0, "move descended through a symlinked folder"
        assert env.nothing_escaped()
        assert os.path.isfile(env.existing), "the source note disappeared"
    finally:
        env.close()


def test_move_refuses_symlinked_source():
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("move", env.vault, "note.md", "moved.md")
        assert r.returncode != 0, "move accepted a symlink as a note"
        assert env.secret_intact()
    finally:
        env.close()


def test_move_relocates_a_real_note():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("move", env.vault, "existing.md", "real/moved.md")
        assert r.returncode == 0, "move failed on a clean path: %r" % r.stderr
        assert not os.path.exists(env.existing), "the source note was left behind"
        assert os.path.isfile(os.path.join(env.vault, "real/moved.md"))
    finally:
        env.close()


def test_move_creates_missing_folders():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("move", env.vault, "existing.md", "fresh/dir/moved.md")
        assert r.returncode == 0, "move failed to make folders: %r" % r.stderr
        assert os.path.isfile(os.path.join(env.vault, "fresh/dir/moved.md"))
    finally:
        env.close()


# --------------------------------------------------------------------- delete


def test_delete_refuses_symlinked_intermediate():
    env = Env(dest_link=False, intermediate_link=True)
    try:
        r = run("delete", env.vault, "linkdir/secret.txt")
        assert r.returncode != 0, "delete reached through a symlinked folder"
        assert os.path.isfile(env.secret), "a file outside the vault was deleted"
    finally:
        env.close()


def test_delete_refuses_to_follow_symlink():
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("delete", env.vault, "note.md")
        # Whether it refuses or unlinks the link itself, the target must live.
        assert env.secret_intact(), "deleting a symlink removed its target"
    finally:
        env.close()


def test_delete_refuses_a_folder():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("delete", env.vault, "real")
        assert r.returncode != 0, "delete removed a folder"
        assert os.path.isdir(os.path.join(env.vault, "real"))
    finally:
        env.close()


def test_delete_removes_a_real_note():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("delete", env.vault, "existing.md")
        assert r.returncode == 0, "delete failed on a real note: %r" % r.stderr
        assert not os.path.exists(env.existing)
    finally:
        env.close()


# --------------------------------------------------------- argument validation


def test_rejects_traversal_and_absolute_paths():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        for rel in ("../escape.md", "a/../../escape.md", "/etc/passwd",
                    "..", "", "a//b.md", "./x.md"):
            for op in ("create", "write", "delete"):
                r = run(op, env.vault, rel, stdin=b"x\n")
                assert r.returncode != 0, "%s accepted %r" % (op, rel)
        assert env.nothing_escaped()
    finally:
        env.close()


def test_rejects_filesystem_root_as_vault():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("create", "/", "etc/nope.md", stdin=b"x\n")
        assert r.returncode != 0, "the filesystem root was accepted as a vault"
    finally:
        env.close()


def test_symlinked_vault_root_is_usable():
    """A vault symlinked onto another disk, or into a synced folder, is a
    legitimate setup and must keep working."""
    env = Env(dest_link=False, intermediate_link=False)
    try:
        link = os.path.join(env.tmp, "vaultlink")
        os.symlink(env.vault, link)

        r = run("create", link, "viacreate.md", stdin=b"# via the link\n")
        assert r.returncode == 0, "create through a symlinked vault failed: %r" % r.stderr
        # and it landed in the real vault, not beside the link
        assert os.path.isfile(os.path.join(env.vault, "viacreate.md"))

        r = run("write", link, "existing.md", stdin=b"# written via the link\n")
        assert r.returncode == 0, "write through a symlinked vault failed: %r" % r.stderr

        r = run("move", link, "existing.md", "real/moved.md")
        assert r.returncode == 0, "move through a symlinked vault failed: %r" % r.stderr
        assert os.path.isfile(os.path.join(env.vault, "real/moved.md"))

        r = run("delete", link, "viacreate.md")
        assert r.returncode == 0, "delete through a symlinked vault failed: %r" % r.stderr
    finally:
        env.close()


def test_symlinked_vault_root_still_contains_writes():
    """The important half.

    Allowing a symlinked *root* must not loosen anything *inside* the vault. A
    root is configuration the user chose; its contents arrived by clone or sync
    and are hostile. These are the same attacks as elsewhere in this file, run
    through a symlinked root, and they must all still be refused.
    """
    env = Env(dest_link=True, intermediate_link=True)
    try:
        link = os.path.join(env.tmp, "vaultlink")
        os.symlink(env.vault, link)

        r = run("create", link, "note.md", stdin=b"attacker controlled\n")
        assert r.returncode != 0, "create followed a symlinked note through the root"
        assert env.secret_intact(), "the file behind the note symlink was modified"

        r = run("create", link, "linkdir/x.md", stdin=b"escaped\n")
        assert r.returncode != 0, "create descended through a symlinked folder"
        assert env.nothing_escaped(), "a file was created outside the vault"

        r = run("write", link, "note.md", stdin=b"clobbered\n")
        assert r.returncode != 0, "write followed a symlinked note through the root"
        assert env.secret_intact()

        r = run("delete", link, "linkdir/secret.txt")
        assert r.returncode != 0, "delete reached outside through a symlinked folder"
        assert os.path.isfile(env.secret)

        r = run("move", link, "real/inner.md", "linkdir/moved.md")
        assert r.returncode != 0, "move escaped through a symlinked folder"
        assert env.nothing_escaped()
    finally:
        env.close()


def test_rejects_filesystem_root_behind_a_symlink():
    """Resolving the root must not become a way to reach /."""
    env = Env(dest_link=False, intermediate_link=False)
    try:
        # A symlink named believably, pointing at the filesystem root.
        sneaky = os.path.join(env.tmp, "notes")
        os.symlink("/", sneaky)
        r = run("create", sneaky, "etc/nope.md", stdin=b"x\n")
        assert r.returncode != 0, "a symlink to / was accepted as a vault"
        assert not os.path.exists("/etc/nope.md")
    finally:
        env.close()


def test_rejects_unknown_op():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = run("frobnicate", env.vault, "x.md")
        assert r.returncode == 2, "an unknown op should be a usage error"
    finally:
        env.close()


def test_refused_create_leaves_nothing_behind():
    """A refusal must be all-or-nothing: no zero-byte note on disk."""
    env = Env(dest_link=True, intermediate_link=False)
    try:
        r = run("create", env.vault, "note.md", stdin=b"x\n")
        assert r.returncode != 0
        assert os.path.islink(env.dest_link), "the symlink was replaced"
        # nothing new anywhere in the vault
        assert sorted(os.listdir(env.vault)) == ["existing.md", "note.md", "real"]
    finally:
        env.close()


def test_large_body_is_refused_not_buffered_forever():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        r = subprocess.run(
            [sys.executable, HELPER, "create", env.vault, "big.md"],
            input=b"x" * (17 * 1024 * 1024),
            capture_output=True,
        )
        assert r.returncode != 0, "a 17 MiB note was accepted"
        assert not os.path.exists(
            os.path.join(env.vault, "big.md")
        ), "the refused note was left on disk"
    finally:
        env.close()


def test_symlinked_folder_is_a_clean_refusal_not_a_raw_errno():
    """Linux reports ENOTDIR, not ELOOP, for a symlink opened no-follow.

    Without handling that, the refusal still holds -- nothing is written
    outside -- but it surfaces as a raw errno, and the panel falls back to a
    generic failure message instead of saying what happened.
    """
    env = Env(dest_link=False, intermediate_link=True)
    try:
        for op, rels in (
            ("create", ("linkdir/note.md",)),
            ("write", ("linkdir/note.md",)),
            ("move", ("existing.md", "linkdir/moved.md")),
            ("delete", ("linkdir/secret.txt",)),
        ):
            r = run(op, env.vault, *rels, stdin=b"x\n")
            assert r.returncode == 3, "%s exited %d, expected a refusal" % (op, r.returncode)
            assert b"os error" not in r.stderr, (
                "%s leaked a raw errno: %r" % (op, r.stderr[:120])
            )
        assert env.nothing_escaped()
        assert os.path.isfile(env.secret)
    finally:
        env.close()


def test_rejected_body_leaves_the_note_intact():
    """The bug this covers: op_write used to open O_TRUNC and only then read
    stdin, so a body it went on to reject left the note as zero bytes with the
    save reported as failed. Silent data loss."""
    env = Env(dest_link=False, intermediate_link=False)
    try:
        original = open(env.existing, "rb").read()
        r = run("write", env.vault, "existing.md", stdin=b"x" * (17 * 1024 * 1024))
        assert r.returncode != 0, "an oversized body was accepted"
        assert open(env.existing, "rb").read() == original, (
            "the note was truncated by a write that then failed"
        )
        assert os.path.getsize(env.existing) > 0, "the note was emptied"
    finally:
        env.close()


def test_failed_write_leaves_no_temp_files_behind():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        before = sorted(os.listdir(env.vault))
        r = run("write", env.vault, "existing.md", stdin=b"x" * (17 * 1024 * 1024))
        assert r.returncode != 0
        assert sorted(os.listdir(env.vault)) == before, "a temp file was left behind"
    finally:
        env.close()


def test_write_preserves_the_notes_permissions():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        os.chmod(env.existing, 0o640)
        r = run("write", env.vault, "existing.md", stdin=b"# updated\n")
        assert r.returncode == 0, "write failed: %r" % r.stderr
        mode = os.stat(env.existing).st_mode & 0o777
        assert mode == 0o640, "permissions changed to %o" % mode
    finally:
        env.close()


def test_write_leaves_no_temp_files_on_success():
    env = Env(dest_link=False, intermediate_link=False)
    try:
        before = sorted(os.listdir(env.vault))
        r = run("write", env.vault, "existing.md", stdin=b"# updated\n")
        assert r.returncode == 0
        assert sorted(os.listdir(env.vault)) == before
    finally:
        env.close()


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            check(name[5:], fn)

    print("\nnether_vault: %d passed, %d failed" % (len(PASSED), len(FAILED)))
    for name, why in FAILED:
        print("  FAIL %s: %s" % (name, why))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
