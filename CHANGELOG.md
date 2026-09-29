# Changelog

All notable changes to this project will be documented in this file.

## [1.2.1] - 2026-09-29

### Security
- **Every write to the vault now goes through `nether_vault.py`**, which
  confines it to the vault. This fixes the remaining finding on submission
  #8259 and three related ones found while checking it.

  Creating a note ran `mkdir -p -- … && cat > "$2"`. Shell redirection opens
  `O_WRONLY|O_CREAT|O_TRUNC`, which **follows a symlink at the destination**, so
  a note name already occupied by a link pointing elsewhere had that file
  truncated and then overwritten with note text. Verified concretely: a 34-byte
  file became 0 bytes. The name was not even visible as taken, because the note
  list comes from `find -type f` and a symlink is not type `f` — so the
  duplicate-name check could not fire either.

  A lexical check cannot prevent this, because it never touches the filesystem.
  The helper opens the vault once and resolves every path component from that
  descriptor with `O_NOFOLLOW`, so a symlinked folder fails with `ELOOP` and no
  descriptor into the link target is ever obtained. Creating uses
  `O_CREAT|O_EXCL`, which POSIX makes fail with `EEXIST` when the final
  component is a symlink regardless of its target. The open that writes is the
  same syscall that checks containment, so there is no window between validating
  a path and using it.

  The same root cause affected three paths not previously flagged:
  - `mkdir -p … && mv` could create folders and move a note through a symlinked
    intermediate directory
  - `mv` on its own could move a note out through a symlinked folder
  - `rm -f` could delete a file outside the vault through one

  Autosave previously went through Quickshell's `FileView`. That is safe against
  a symlink at the note path — it uses `QSaveFile`, whose `rename` replaces a
  symlink rather than following it — but exposed to a symlinked folder, and
  `FileView` offers no way to ask for `O_NOFOLLOW`. The write now goes through
  the helper as well; `FileView` remains the reader and the change watcher, so
  external-edit detection is unaffected.

  A move onto an occupied destination is now refused rather than silently
  replacing what was there, and a refused create removes its partial file
  instead of leaving a zero-byte note. Moving or deleting a symlink is refused
  rather than quietly destroying it. `/` and the home directory are rejected as
  vault roots. Traversal and absolute paths are refused by the helper itself as
  well as by `PathGuard.js`, since it is reachable from the shell.

- `tests/test_vault_ops.py` (25 tests) plants a `.md` symlink to a file outside
  the vault and a symlinked intermediate folder, and asserts for every operation
  that it is refused, the outside file is byte-for-byte unchanged, and nothing
  was created outside. Happy paths are covered for all five operations, so a
  suite that refused everything would fail. Run against the previous
  path-based implementation the suite scores 6/25, which is how it is shown to
  detect the vulnerability rather than pass vacuously. Wired into CI.

### Requirements
- Python 3.8+ (standard library only) is required again. It is the sole
  enforcement point for every write, fails closed, and is what confines those
  writes to the vault. It was previously required for the auto-delete sweep,
  which no longer exists.

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
- Note paths and markdown links are validated in one place (`PathGuard.js`)
  - `selectNote` accepted any string and handed it to the note file, which both
    reads and writes. Any process able to reach the shell's IPC socket could
    name a path outside the vault and have it read into the panel and written
    back on the next save. It now only accepts a path the vault scan produced
  - Clicking a link in a note passed the raw target to `xdg-open`, so a synced
    or shared note could choose its own handler — a `file:` link opens an
    arbitrary local path with whatever the desktop registered for it — or pass a
    target `xdg-open` would read as an option. Link handling is now limited to
    `http`, `https` and `mailto`
  - Folder and path construction concatenated strings directly, and the folder
    check refused `..` as a substring, which also refused the legitimate folder
    `notes..archive`
  - The vault picker and the link launcher shared one `Process` for three
    different commands, so a pending pick could be clobbered by a link click
  - `PathGuard.js` omits `.pragma library` so `tests/test_pathguard.mjs` imports
    the file that ships rather than a copy of it
- The vault path is persisted through the shell's own `updateEntryInline` API
  instead of shelling out to python3 to rewrite `shell.json`. `json.dump()`
  truncates the file before writing it, so an interrupted write left the
  desktop's bar config corrupt
- Content search and the note scan are bounded at every stage; see Limits below
- The query was passed where `rg` would read a leading `-` as an option, so
  searching for `--version` made `rg` print its version banner and exit
- `status` no longer reports the vault path to any same-user IPC caller

### Fixed
- Notes larger than ~2.7 MB could not be created at all: the body was passed as
  a process argument, so the write failed with "Argument list too long" and no
  file was created. It is now written over stdin
- A note changed elsewhere while Nether held unsaved edits was silently
  overwritten on the next autosave. The conflict is now reported and the
  on-disk version is retained
- A content search still running when the query changed could deliver its
  results afterwards and overwrite fresher ones

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