#!/usr/bin/env python3
"""
Filesystem operations for the Nether plugin, with every write confined to the
vault.

A vault is not necessarily trustworthy. It can be a git clone, a synced folder,
or something someone shared with you, so it may contain symbolic links that
point anywhere on the filesystem. Plain path-based tools cannot defend against
that: shell redirection follows a symlink at the destination, and mkdir/rm/mv
resolve every intermediate directory component as a normal path lookup. A
lexical check such as "does this string start with the vault path" cannot see
any of it, because it never touches the filesystem.

So nothing here is a check-then-use. Every operation resolves a path one
component at a time from a descriptor opened on the vault itself, with
O_NOFOLLOW on each step, and the open that performs the write is the same
syscall that enforces containment. There is no window between validating a
path and using it.

Each op is a separate argv-driven invocation:

    nether_vault.py <op> <vault> <rel> [<rel2>]

and the body for `create`/`write` arrives on stdin. A refusal is a non-zero
exit with a message on stderr; nothing is ever done on a best-effort basis.
"""
import errno
import os
import stat
import sys

# Refusals are reported as a distinct exit code so the caller can tell
# "refused for safety" from "the disk is broken" and say something useful.
EXIT_REFUSED = 3
EXIT_USAGE = 2

# Guard against a pathological relative path turning into an enormous walk.
MAX_COMPONENTS = 64
MAX_NAME = 255


class Refused(Exception):
    """The operation was declined because it would leave, or risk, the vault."""


def _split_rel(rel):
    """Validate a vault-relative path and return its components.

    Deliberately redundant with the QML-side guard: this process is reachable
    from the shell as well, so it does not trust its arguments to have been
    vetted by PathGuard.js. Absolute paths, empty/dot/dotdot components and
    NUL bytes are all refused.
    """
    if not isinstance(rel, str) or rel == "":
        raise Refused("empty path")
    if "\x00" in rel:
        raise Refused("path contains a NUL byte")
    if rel.startswith("/"):
        raise Refused("path must be vault-relative, not absolute")
    parts = rel.split("/")
    if len(parts) > MAX_COMPONENTS:
        raise Refused("path has too many components")
    for part in parts:
        if part == "":
            raise Refused("path has an empty component")
        if part in (".", ".."):
            raise Refused("path has a %r component" % part)
        if len(part.encode("utf-8")) > MAX_NAME:
            raise Refused("path component is too long")
    return parts


def _open_vault(vault):
    """Open a descriptor on the vault root, refusing implausible roots.

    O_NOFOLLOW applies here too: if the configured vault is itself a symlink
    the user is told so rather than silently being redirected. A symlinked
    vault is a legitimate thing to want, but it has to be a deliberate choice,
    so the shell resolves it before configuring the path.
    """
    if not vault:
        raise Refused("no vault configured")
    resolved = os.path.realpath(vault)
    if resolved == "/":
        raise Refused("refusing to use the filesystem root as a vault")
    try:
        return os.open(
            vault, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        )
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise Refused("the vault path is a symbolic link")
        if exc.errno == errno.ENOENT:
            raise Refused("no vault at that path")
        raise


def _open_parent(vault_fd, parts):
    """Walk every component but the last, returning (dir_fd, final_name).

    This is the step that defeats a symlinked intermediate directory. Each
    component is opened relative to the previous descriptor with O_NOFOLLOW,
    so a symlink yields ELOOP and no descriptor into the link target is ever
    obtained. Handing the kernel "a/b/c" in one call instead would resolve "a"
    as an ordinary path lookup, which is the bug this replaces.
    """
    dir_fd = os.dup(vault_fd)
    try:
        for part in parts[:-1]:
            nxt = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=dir_fd,
            )
            os.close(dir_fd)
            dir_fd = nxt
        return dir_fd, parts[-1]
    except OSError as exc:
        os.close(dir_fd)
        if exc.errno == errno.ELOOP:
            raise Refused("a folder in the path is a symbolic link")
        if exc.errno == errno.ENOTDIR:
            raise Refused("a path component is not a folder")
        if exc.errno == errno.ENOENT:
            raise Refused("no such folder in the vault")
        raise
    except BaseException:
        os.close(dir_fd)
        raise


def _open_existing(parent_fd, name, flags):
    """Open the final component without following it, as a regular file.

    O_NOFOLLOW means a symlink here fails with ELOOP rather than being written
    through, and the S_ISREG check rejects fifos, devices and directories.
    """
    try:
        fd = os.open(name, flags | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise Refused("the target is a symbolic link")
        raise
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused("the target is not a regular file")
    except BaseException:
        os.close(fd)
        raise
    return fd


def _read_stdin():
    chunks = []
    total = 0
    while True:
        chunk = sys.stdin.buffer.read(65536)
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        # A note larger than this is not a note. The old argv-based create
        # failed on anything past ARG_MAX anyway, but with a far less obvious
        # error, so fail loudly instead of buffering without limit.
        if total > 16 * 1024 * 1024:
            raise Refused("refusing to write more than 16 MiB in one operation")
    return b"".join(chunks)


def _fsync_dir(dir_fd):
    try:
        os.fsync(dir_fd)
    except OSError:
        # Not all filesystems allow fsync on a directory; the data write is
        # already fsynced, so this is not worth failing the operation over.
        pass


# ------------------------------------------------------------------ operations


def op_create(vault, rel):
    """Create a new empty-ish file, refusing if anything already exists there.

    O_CREAT|O_EXCL is the whole point: POSIX makes it fail with EEXIST when the
    final component is a symbolic link, regardless of where the link points, so
    a note name that collides with a planted symlink simply cannot be written.
    That is the attack where `cat >` truncated an unrelated file to zero bytes
    and then filled it with note text.
    """
    parts = _split_rel(rel)
    vault_fd = _open_vault(vault)
    try:
        # Folders first: a new note may name a folder that does not exist yet,
        # and _open_parent needs them present to hand back a descriptor.
        _mkdir_parents(vault_fd, parts)
        # Consume the body before creating anything, so a refusal of any kind
        # leaves no empty file behind. Creating first and reading second left a
        # zero-byte note on disk whenever the body was rejected.
        data = _read_stdin()
        parent_fd, name = _open_parent(vault_fd, parts)
        try:
            try:
                fd = os.open(
                    name,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_NOFOLLOW
                    | os.O_CLOEXEC,
                    0o600,
                    dir_fd=parent_fd,
                )
            except OSError as exc:
                if exc.errno == errno.EEXIST:
                    raise Refused("a note already exists at that path")
                if exc.errno == errno.ELOOP:
                    raise Refused("the target is a symbolic link")
                raise
            try:
                os.fchmod(fd, 0o666 & ~_umask())
                if data:
                    os.write(fd, data)
                os.fsync(fd)
            except BaseException:
                # A write that failed part way (out of space, say) would leave
                # a truncated note. Remove it so the next save starts clean
                # rather than writing on top of a partial file.
                os.close(fd)
                try:
                    os.unlink(name, dir_fd=parent_fd)
                except OSError:
                    pass
                raise
            else:
                os.close(fd)
            _fsync_dir(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        os.close(vault_fd)


def op_write(vault, rel):
    """Overwrite an existing note's contents in place.

    O_NOFOLLOW still applies, so if the note was replaced by a symlink between
    being opened and being saved, this refuses rather than writing through it.
    """
    parts = _split_rel(rel)
    vault_fd = _open_vault(vault)
    try:
        parent_fd, name = _open_parent(vault_fd, parts)
        try:
            fd = _open_existing(parent_fd, name, os.O_WRONLY | os.O_TRUNC)
            try:
                data = _read_stdin()
                if data:
                    os.write(fd, data)
                os.fsync(fd)
            finally:
                os.close(fd)
            _fsync_dir(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        os.close(vault_fd)


def op_move(vault, src_rel, dst_rel):
    """Rename or move a note within the vault.

    os.replace is rename(2): it replaces a symlink at the destination rather
    than following it, and passing src_dir_fd/dst_dir_fd keeps both sides
    anchored on descriptors we opened no-follow, so no intermediate directory
    can redirect the move.
    """
    src_parts = _split_rel(src_rel)
    dst_parts = _split_rel(dst_rel)
    vault_fd = _open_vault(vault)
    try:
        src_parent, src_name = _open_parent(vault_fd, src_parts)
        try:
            # The source must be a real file we can account for, not a symlink
            # that would be carried around as a note.
            probe = _open_existing(src_parent, src_name, os.O_RDONLY)
            os.close(probe)

            _mkdir_parents(vault_fd, dst_parts)
            dst_parent, dst_name = _open_parent(vault_fd, dst_parts)
            try:
                # Refuse an occupied destination rather than clobbering it.
                # rename(2) would happily replace a symlink there, which is
                # safe for the file it points at but silently destroys the
                # link, and find -type f never listed it so the caller has no
                # way of knowing the name was taken.
                try:
                    taken = os.lstat(dst_name, dir_fd=dst_parent)
                except OSError as exc:
                    if exc.errno != errno.ENOENT:
                        raise
                else:
                    kind = "a symbolic link" if stat.S_ISLNK(taken.st_mode) else "something"
                    raise Refused("refusing to replace %s at that path" % kind)

                os.replace(
                    src_name, dst_name, src_dir_fd=src_parent, dst_dir_fd=dst_parent
                )
                _fsync_dir(dst_parent)
            finally:
                os.close(dst_parent)
        finally:
            os.close(src_parent)
    finally:
        os.close(vault_fd)


def op_delete(vault, rel):
    """Unlink a note. os.unlink removes a symlink itself, never its target."""
    parts = _split_rel(rel)
    vault_fd = _open_vault(vault)
    try:
        parent_fd, name = _open_parent(vault_fd, parts)
        try:
            try:
                st = os.lstat(name, dir_fd=parent_fd)
            except OSError as exc:
                if exc.errno == errno.ENOENT:
                    raise Refused("no note at that path")
                raise
            if stat.S_ISDIR(st.st_mode):
                raise Refused("refusing to delete a folder")
            os.unlink(name, dir_fd=parent_fd)
            _fsync_dir(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        os.close(vault_fd)


def _umask():
    mask = os.umask(0)
    os.umask(mask)
    return mask


def _mkdir_parents(vault_fd, parts):
    """Create any missing intermediate folders, one anchored step at a time.

    os.mkdir(…, dir_fd=) has no O_NOFOLLOW, so each level is opened no-follow
    after creation and re-verified with fstat before descending. A symlink
    already sitting at one of those names is therefore caught rather than
    joined.
    """
    dir_fd = os.dup(vault_fd)
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, 0o755, dir_fd=dir_fd)
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    if exc.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise Refused("a folder in the path is a symbolic link")
                    raise
            nxt = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=dir_fd,
            )
            os.close(dir_fd)
            dir_fd = nxt
    except OSError as exc:
        os.close(dir_fd)
        # Linux reports ENOTDIR rather than ELOOP when a symlink is opened with
        # O_NOFOLLOW|O_DIRECTORY, so both have to be caught or a symlinked
        # folder escapes as a raw errno instead of a refusal.
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refused("a folder in the path is a symbolic link")
        if exc.errno == errno.ENOENT:
            raise Refused("no such folder in the vault")
        raise
    except BaseException:
        os.close(dir_fd)
        raise


OPS = {
    "create": op_create,
    "write": op_write,
    "move": op_move,
    "delete": op_delete,
}


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: nether_vault.py <op> <vault> <rel> [<rel>]\n")
        return EXIT_USAGE
    op_name, vault = argv[0], argv[1]
    rels = argv[2:]
    handler = OPS.get(op_name)
    if handler is None:
        sys.stderr.write("unknown op: %s\n" % op_name)
        return EXIT_USAGE
    try:
        if op_name == "move":
            if len(rels) != 2:
                sys.stderr.write("move takes a source and a destination\n")
                return EXIT_USAGE
            handler(vault, rels[0], rels[1])
        else:
            if len(rels) != 1:
                sys.stderr.write("%s takes exactly one path\n" % op_name)
                return EXIT_USAGE
            handler(vault, rels[0])
    except Refused as exc:
        sys.stderr.write("%s\n" % exc)
        return EXIT_REFUSED
    except OSError as exc:
        sys.stderr.write("os error: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
