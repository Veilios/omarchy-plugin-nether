#!/usr/bin/env python3
"""
Security test: Symlinks in vault cannot modify files outside vault.
Run: python3 tests/test_symlink_protection.py
"""
import os
import tempfile
import shutil
import subprocess
import sys
import stat

# Import the function under test (will fail initially - that's expected)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from nether_auto_delete import process_vault


def test_symlink_cannot_escape_vault():
    """A .md symlink pointing outside vault must not modify the target."""
    with tempfile.TemporaryDirectory() as vault_dir:
        # Legitimate note with old completed task (should be removed)
        # Use a timestamp from 1 hour ago for "recent" task
        from datetime import datetime, timedelta
        recent_ts = (datetime.now() - timedelta(hours=1)).isoformat()
        note_path = os.path.join(vault_dir, "legitimate.md")
        with open(note_path, "w") as f:
            f.write("- [x] Old task <!-- completed: 2020-01-01T00:00:00 -->\n")
            f.write(f"- [x] Recent task <!-- completed: {recent_ts} -->\n")

        # Symlink to file OUTSIDE vault
        outside_dir = tempfile.mkdtemp(prefix="nether_test_outside_")
        target_path = os.path.join(outside_dir, "secret.txt")
        with open(target_path, "w") as f:
            f.write("ORIGINAL CONTENT - MUST NOT CHANGE\n")

        symlink_path = os.path.join(vault_dir, "evil.md")
        os.symlink(target_path, symlink_path)

        # Second symlink (edge case: symlink to directory containing file)
        outside_dir2 = tempfile.mkdtemp(prefix="nether_test_outside2_")
        target_file2 = os.path.join(outside_dir2, "another.txt")
        with open(target_file2, "w") as f:
            f.write("ALSO ORIGINAL\n")
        symlink_path2 = os.path.join(vault_dir, "evil2.md")
        os.symlink(target_file2, symlink_path2)

        # Run the code
        process_vault(vault_dir)

        # ASSERTIONS - these must all pass after fix
        with open(target_path, "r") as f:
            assert f.read() == "ORIGINAL CONTENT - MUST NOT CHANGE\n", "SECURITY BREACH: outside file modified!"

        with open(target_file2, "r") as f:
            assert f.read() == "ALSO ORIGINAL\n", "SECURITY BREACH: second outside file modified!"

        with open(note_path, "r") as f:
            content = f.read()
            assert "Old task" not in content, "Old task should be removed"
            assert "Recent task" in content, "Recent task should be preserved"

        assert os.path.islink(symlink_path), "Symlink was replaced!"
        assert os.path.islink(symlink_path2), "Second symlink was replaced!"
        assert os.readlink(symlink_path) == target_path, "Symlink target changed!"
        assert os.readlink(symlink_path2) == target_file2, "Second symlink target changed!"

        shutil.rmtree(outside_dir)
        shutil.rmtree(outside_dir2)
        print("✅ TEST PASSED: Symlink cannot escape vault")


def test_regular_files_still_work():
    """Normal .md files without symlinks must still be processed correctly."""
    with tempfile.TemporaryDirectory() as vault_dir:
        note_path = os.path.join(vault_dir, "normal.md")
        with open(note_path, "w") as f:
            f.write("- [x] Old task <!-- completed: 2020-01-01T00:00:00 -->\n")
            f.write("- [ ] Incomplete task\n")
            f.write("Some regular text\n")

        process_vault(vault_dir)

        with open(note_path, "r") as f:
            content = f.read()
            assert "Old task" not in content, "Old completed task should be removed"
            assert "Incomplete task" in content, "Incomplete task should remain"
            assert "Some regular text" in content, "Regular text should remain"
        print("✅ TEST PASSED: Regular files work correctly")


def test_nested_symlinks():
    """Symlinks in subdirectories must also be contained."""
    with tempfile.TemporaryDirectory() as vault_dir:
        subdir = os.path.join(vault_dir, "subfolder")
        os.makedirs(subdir)

        outside_dir = tempfile.mkdtemp(prefix="nether_test_nested_")
        target_path = os.path.join(outside_dir, "nested.txt")
        with open(target_path, "w") as f:
            f.write("NESTED ORIGINAL\n")

        symlink_path = os.path.join(subdir, "nested_evil.md")
        os.symlink(target_path, symlink_path)

        process_vault(vault_dir)

        with open(target_path, "r") as f:
            assert f.read() == "NESTED ORIGINAL\n", "Nested symlink escaped!"
        assert os.path.islink(symlink_path), "Nested symlink replaced!"

        shutil.rmtree(outside_dir)
        print("✅ TEST PASSED: Nested symlinks contained")


def test_broken_symlink():
    """Broken symlinks must not crash the process."""
    with tempfile.TemporaryDirectory() as vault_dir:
        broken_link = os.path.join(vault_dir, "broken.md")
        os.symlink("/nonexistent/path", broken_link)

        # Should not raise
        process_vault(vault_dir)
        assert os.path.islink(broken_link), "Broken symlink was modified!"
        print("✅ TEST PASSED: Broken symlinks handled gracefully")


if __name__ == "__main__":
    test_symlink_cannot_escape_vault()
    test_regular_files_still_work()
    test_nested_symlinks()
    test_broken_symlink()
    print("\n🎉 ALL TESTS PASSED")