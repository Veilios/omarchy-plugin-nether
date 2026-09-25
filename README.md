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
- Python 3.6+ (for secure vault processing)
- ripgrep (`rg`) for full-text content search

## License

MIT — see [LICENSE](LICENSE)

## Author

veilios
