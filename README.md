# Nether

**Obsidian vault notes in your Omarchy bar.** Read, edit, search, and manage Markdown notes without leaving your desktop.

![Nether preview]<img width="924" height="1076" alt="screenshot-2026-09-22_21-47-56" src="https://github.com/user-attachments/assets/f205abdb-7bb5-4f31-9604-3dcd5a63bd5d" />

## Features

- **Bar widget** — Click the icon to open a panel with your notes
- **Full Markdown rendering** — Headers, lists, code blocks, blockquotes, tables, tasks
- **Vault folder navigation** — Create, move, and organize notes by folder
- **Search** — Fuzzy search across note names and full content (`Ctrl+S`)
- **Auto-save** — Edits persist instantly; reverts to read-only on note switch
- **Keyboard Support** — The entire plugin is mostly navigable with just the keyboard, as dhh intended 

## Installation

### Via Omarchy Plugin Manager (Recommended)

```bash
omarchy plugin add https://github.com/veilios/omarchy-plugin-nether.git --enable
```

### Manual

```bash
git clone https://github.com/veilios/omarchy-plugin-nether.git \
  ~/.config/omarchy/plugins/veilios.nether
omarchy-restart-shell
```

Then enable in your bar config or via `omarchy plugin list`.

## Configuration

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `vaultPath` | string | `~/Documents/Obsidian Vault` | Path to your Obsidian vault (supports `~`) |

Configure via:
- `omarchy plugin config veilios.nether` (interactive)
- Edit `~/.config/omarchy/shell.json` directly
- Right-click bar widget → Settings

## Usage

### Opening the Panel

- Click the Nether icon in the bar
- IPC: `omarchy-shell veilios.nether toggle`

### Navigation

| Key | Action |
|-----|--------|
| `↑/↓` / `J/K` | Navigate notes / task cursor |
| `PgUp/PgDn` | Scroll note content |
| `←/→` | Horizontal: header tabs, footer actions |
| `Tab` / `Shift+Tab` | Cycle focus between sections |
| `Enter` / `Space` | Open note / Toggle task |
| `Escape` | Close panels / Return to header |

### Shortcuts (Ctrl+)

| Key | Action |
|-----|--------|
| `Ctrl+K` | Toggle Quick Keys reference |
| `Ctrl+N` | New note |
| `Ctrl+X` | Delete note (read mode) |
| `Ctrl+D` | Delete task (on completed task) |
| `Ctrl+Enter` | Toggle edit / read-only |
| `Ctrl+S` | Search notes (names + content) |
| `Ctrl+M` | Move note |

### Section-Specific

| Section | Keys |
|---------|------|
| **Header** | `←/→` Switch tabs, `↓` Enter content |
| **Read** | `Enter/Space/L` Toggle task, `→` Focus delete (completed), `←` Return |
| **Search** | `↑/↓` Select, `→/Enter` Open, `←` Back to input |
| **Create/Move** | `Tab` Cycle (title→folders→buttons), `→` Submit, `←` Cancel |
| **Settings** | `↑/↓/←/→` Navigate, `Enter` Activate |
| **Task Input** | `↑/↓` Traverse, `Tab/Shift+Tab` Cycle |
| **Delete Confirm** | `←/→` Select No/Yes, `Enter` Confirm |

### Quick Keys Reference

Press `Ctrl+K` inside the panel for a compact shortcut cheatsheet.

Press `Hot Keys` button in Settings for the full categorized reference.

## Creating Notes

1. Press `Ctrl+N` or click **New Note** in header
2. Enter title
3. Select folder (or create new with `+` button)
4. Press `Create` or `→`

## Moving Notes

1. Open note, and press `Ctrl+M`
2. Select destination folder (or create new)
3. Press `Move` or `→`

## Deleting Notes

1. Open note in read mode, press `Ctrl+X` (sorry, I use blender)
2. Confirm in dialog

## Requirements

- Omarchy (Quickshell-based shell)
- Obsidian vault with `.md` files
- ripgrep (`rg`) for full-text content search
- `xdg-open`, to follow links in a note
- Python 3.8+ (stdlib only) — every write to your vault goes through
  `nether_vault.py`, which is what confines those writes to the vault

## IPC

Nether registers a `veilios.nether` IPC target, reachable by any process
running as your user via `omarchy-shell`:

```bash
omarchy-shell veilios.nether toggle
omarchy-shell veilios.nether selectIndex 3
omarchy-shell veilios.nether selectNote projects/plan.md
omarchy-shell veilios.nether status
```

`selectNote` only accepts a path the vault scan actually produced and returns
`unknown-note` for anything else, so the target cannot be used to read or write
outside the vault. `status` deliberately does not report the vault path.

## How Nether writes to your vault

Your vault is treated as untrusted input. It may be a git clone, a synced
folder, or something someone shared with you, so a note name inside it may
already be occupied by a symbolic link pointing anywhere on your filesystem.

Plain tools cannot defend against that. Shell redirection follows a symlink at
the destination, and `mkdir`, `mv` and `rm` resolve every intermediate folder
as an ordinary path lookup — so a note called `todo.md` that is secretly a link
to your `.bashrc` would have that file truncated and overwritten. A path
*string* check cannot see any of it, because it never looks at the filesystem.

So Nether does not write with path-based tools at all. Every create, rename,
move, delete and autosave goes through `nether_vault.py`, which resolves each
path component from a descriptor with `O_NOFOLLOW`. Creating a note uses
`O_CREAT|O_EXCL`, so a name already taken by *anything* — including a symlink —
is refused rather than written through. The operation that writes is the same
syscall that checks containment, so there is no window between validating a path
and using it.

The trust boundary is the vault root, and the two halves are treated
differently on purpose. The root is *configuration* — you named it, so it is
trusted like any path you type, and a vault that is a symlink onto another disk
works. Its *contents* are hostile, because they can arrive by clone or sync,
so every component below the root is opened no-follow. A symlink pointing at
`/` is refused even when reached through a link.

Saves are atomic: the note is written to a temporary file and renamed over the
top, so a failure part way through leaves the previous contents intact.

If an operation is refused, the panel says why and nothing is written. Refusals
also leave nothing behind: a create that cannot finish removes the partial file
rather than leaving a zero-byte note.

`tests/test_vault_ops.py` covers this. It plants a `.md` symlink pointing at a
file outside the vault, and a symlinked intermediate folder, then asserts for
every operation that it is refused, that the file on the other side of the link
is byte-for-byte unchanged, and that nothing appeared outside the vault. The
same suite passes 6/25 against the previous path-based implementation, which is
how the tests are shown to be testing something rather than passing vacuously.

## Limits

Search and the note list are bounded, because both run inside the long-lived
shell process. Content search caps matches per file, file size, directory depth,
total output bytes and the number of files retained; the note list is capped at
20,000 notes. When a cap is hit the panel says so rather than silently showing
part of the result — narrow the search, or move the offending notes.

## License

MIT — see [LICENSE](LICENSE)

## Author

veilios
