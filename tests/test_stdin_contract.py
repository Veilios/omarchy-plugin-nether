#!/usr/bin/env python3
"""
Integration test for the stdin contract between Quickshell and the helper.

Every op that carries a note body reads it from stdin until EOF. In the UI,
the write side is Quickshell's Process.write(): it delivers the bytes but
does NOT close the pipe. The shell therefore has to set
`stdinEnabled = false` after write(), or the helper blocks in its read loop
forever -- nothing is written and no error is ever reported. The liveness
contract matters more than the bytes: a helper that requires EOF but never
gets it looks exactly like the process failing.

This suite mirrors the shell's sequence (spawn, write, close) rather than
subprocess.run(input=...), which closes stdin internally and cannot exercise
the contract.

Run: python3 tests/test_stdin_contract.py
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
    except Exception as exc:  # noqa: BLE001 - a crashing test is a failing test
        FAILED.append((name, "%s: %s" % (type(exc).__name__, exc)))


def quickshell_like(op, vault, rel, body, timeout=5):
    """Spawn the helper and feed it a body the way Quickshell does: write,
    then close stdin. A hang surfaces as a TimeoutExpired."""
    p = subprocess.Popen(
        [sys.executable, HELPER, op, vault, rel],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        p.stdin.write(body)
        p.stdin.close()
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        raise AssertionError("helper hung waiting for stdin EOF after "
                             "write(); is the UI-side stdinEnabled=false "
                             "close in place?")
    return p.returncode, out, err


def test_create_writes_body():
    tmp = tempfile.mkdtemp(prefix="nether-stdin-test.")
    try:
        vault = os.path.join(tmp, "vault")
        os.makedirs(vault)
        code, out, err = quickshell_like("create", vault, "fresh.md", b"# hello\n")
        assert code == 0, "create exited %d: %s" % (code, err.decode(errors="replace"))
        with open(os.path.join(vault, "fresh.md"), "rb") as f:
            assert f.read() == b"# hello\n", "body not written"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_write_updates_existing_note():
    tmp = tempfile.mkdtemp(prefix="nether-stdin-test.")
    try:
        vault = os.path.join(tmp, "vault")
        os.makedirs(vault)
        note = os.path.join(vault, "existing.md")
        with open(note, "w") as f:
            f.write("old\n")
        code, out, err = quickshell_like("write", vault, "existing.md", b"new body\n")
        assert code == 0, "write exited %d: %s" % (code, err.decode(errors="replace"))
        with open(note, "rb") as f:
            assert f.read() == b"new body\n", "note not replaced"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_create_with_empty_body():
    tmp = tempfile.mkdtemp(prefix="nether-stdin-test.")
    try:
        vault = os.path.join(tmp, "vault")
        os.makedirs(vault)
        code, out, err = quickshell_like("create", vault, "blank.md", b"")
        assert code == 0, "create exited %d: %s" % (code, err.decode(errors="replace"))
        assert os.path.isfile(os.path.join(vault, "blank.md"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    check("create writes body via write-then-close stdin", test_create_writes_body)
    check("write replaces existing note", test_write_updates_existing_note)
    check("create with empty body still terminates", test_create_with_empty_body)
    if FAILED:
        print("stdin-contract: %d failed, %d passed" % (len(FAILED), len(PASSED)))
        for name, err in FAILED:
            print("  FAIL %s -- %s" % (name, err))
        return 1
    print("stdin-contract: %d passed" % len(PASSED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
