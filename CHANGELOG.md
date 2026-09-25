# Changelog

All notable changes to this project will be documented in this file.

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