#!/usr/bin/env python3
"""
Secure auto-delete task processing for Nether plugin.
Uses descriptor-relative operations to prevent symlink escapes.
"""
import os
import re
import sys
import datetime
import stat
import tempfile


TASK_RE = re.compile(
    r"^(\s*[-*+]\s+\[x\]\s+.*?)\s*<!--\s*completed:\s*([^>\s]+)\s*-->"
)
DAY_SECONDS = 86400


def process_vault(vault: str) -> None:
    """
    Process all .md files in vault, removing completed tasks older than 24 hours.
    SECURITY: Uses O_NOFOLLOW, descriptor-relative ops, atomic writes.
    """
    now = datetime.datetime.now().timestamp()

    # Open vault directory descriptor ONCE, retain it
    vault_fd = os.open(vault, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        # Walk WITHOUT following symlinks, rooted at vault_fd
        for root, dirs, files in os.walk(vault, followlinks=False, topdown=True):
            rel_root = os.path.relpath(root, vault)

            for f in files:
                if not f.endswith(".md"):
                    continue

                # Build relative path for openat
                rel_path = f if rel_root == "." else os.path.join(rel_root, f)

                # Open with O_NOFOLLOW using dir_fd - fails on symlinks
                try:
                    fd = os.open(
                        rel_path,
                        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=vault_fd
                    )
                except (OSError, NotImplementedError):
                    # Symlink, non-regular file, permission issue, or dir_fd unsupported - skip
                    continue

                try:
                    # Verify it's a regular file via fstat
                    st = os.fstat(fd)
                    if not stat.S_ISREG(st.st_mode):
                        continue

                    # Read via file descriptor
                    with os.fdopen(fd, "r") as fp:
                        lines = fp.readlines()
                    fd = None  # fdopen took ownership

                    # Process lines
                    out = []
                    for line in lines:
                        m = TASK_RE.match(line.rstrip("\n"))
                        if m:
                            ts_str = m.group(2)
                            try:
                                ts = datetime.datetime.fromisoformat(
                                    ts_str.replace("Z", "+00:00")
                                ).timestamp()
                                if now - ts <= DAY_SECONDS:
                                    out.append(line)
                            except (ValueError, AttributeError):
                                out.append(line)
                        else:
                            out.append(line)

                    # ATOMIC WRITE: temp file in SAME directory, then rename
                    abs_path = os.path.join(vault, rel_path)
                    dir_name = os.path.dirname(abs_path)

                    tmp_fd, tmp_path = tempfile.mkstemp(
                        dir=dir_name,
                        prefix=".nether.",
                        suffix=".tmp"
                    )
                    try:
                        with os.fdopen(tmp_fd, "w") as fp:
                            fp.writelines(out)
                        # os.rename does NOT follow symlinks on target
                        os.rename(tmp_path, abs_path)
                    except Exception:
                        try:
                            os.unlink(tmp_path)
                        except Exception:
                            pass
                        raise

                finally:
                    if fd is not None:
                        try:
                            os.close(fd)
                        except Exception:
                            pass
    finally:
        os.close(vault_fd)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <vault-path>", file=sys.stderr)
        sys.exit(1)
    process_vault(sys.argv[1])