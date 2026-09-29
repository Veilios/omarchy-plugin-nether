# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-29

### Removed
- **Auto-delete of completed tasks** (the daily vault rewrite), along with
  `nether_auto_delete.py` and `tests/test_symlink_protection.py`
  - The feature was opt-in by nobody: it ran on every shell start and every
    24h, opening every `.md` file in the vault and writing it back through a
    temp file + rename
  - That rewrite discarded each note's original mode (the temp file was created
    `0600`), so it silently stripped permissions and churned every inode in the
    vault daily
  - `O_NOFOLLOW` was only applied to the final path component, and the write
    path used plain pathnames rather than the retained vault descriptor, so an
    intermediate directory swapped for a symlink between walk and write could
    still redirect the rewrite outside the vault
  - A lost-update race also let the pass clobber edits made by Obsidian
    concurrently, since the file was re-read by path rather than compared
  - Notes are now only ever written by an explicit user action. The
    `<!-- completed: ... -->` marker is still written when you tick a task and
    is still round-tripped, it is simply never swept up afterwards

### Security
- Containment and input-validation hardening lands alongside the above:
  unvalidated IPC path handling, the markdown link allowlist, shell settings
  persistence via the shell's own API, and bounded content search. See the
  individual entries below in subsequent releases.

## [1.1.0] - 2026-09-25

### Security
- Fixed symlink vulnerability in auto-delete task processing
  - The auto-delete task feature (runs daily) processes `.md` files in your vault to remove completed tasks older than 24 hours
  - Now uses **descriptor-relative operations with `O_NOFOLLOW`** and **atomic writes** to prevent symlink-based path traversal attacks
  - Symlinks in the vault are safely ignored — they cannot be used to modify files outside the vault
  - Added test suite in `tests/test_symlink_protection.py` validating this protection

### Added
- Full-text fuzzy search using ripgrep (`rg`)
  - Search across note names AND note content (`Ctrl+S`)
  - Content search debounced at 150ms to avoid excessive calls
  - Shows match type indicator (📄) and snippet preview in dropdown
  - Minimum 2 characters required for content search
  - Smart case sensitivity (`--smart-case`)
  - Excludes `.obsidian` folder from search

### Requirements
- Added `ripgrep` (`rg`) as dependency for full-text content search

## [1.0.0] - 2026-09-22

### Initial Release
- Bar widget for Obsidian vault notes
- Full Markdown rendering (headers, lists, code blocks, blockquotes, tables, tasks)
- Task support with inline checkboxes (`- [ ]` / `- [x]`)
- Vault folder navigation (create, move, organize notes)
- Fuzzy search across note names
- Auto-save with read-only revert on note switch
- Session restore (reopens last note on login)
- Keyboard-first navigation with comprehensive hotkeys