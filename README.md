# RAFT

Rapid Access Floating Terminal for [Rex](https://www.superlogical.com/rex).
Nine shell slots per tab, pane, or session. Hiding a terminal keeps its processes running.
Includes a manager with search and output preview.

## Install

1. Clone this repo:

   ```sh
   git clone https://github.com/theboxer/raft.git ~/.config/rex/raft
   ```

2. Add to `~/.config/rex/init.lua`:

   ```lua
   dofile(os.getenv("HOME") .. "/.config/rex/raft/raft.lua").setup {}

   rex.bind("ctrl+s>f", "raft_toggle")
   rex.bind("ctrl+s>q", "raft_hide")
   rex.bind("ctrl+s>shift+f", "raft_manage")
   for slot = 1, 9 do
       rex.bind("ctrl+s>ctrl+f>" .. slot, "raft_toggle", { slot = slot })
   end
   ```

   Run `rex config reload` to apply.

## Configuration

Replace the `setup {}` with options as needed:

```lua
dofile(os.getenv("HOME") .. "/.config/rex/raft/raft.lua").setup {
    scope = "session",                -- default for all sessions
    sessions = {                      -- optional overrides by session name
        work = "tab",
        ["my-project"] = "pane",
    },
    bounds = { 0.1, 0.1, 0.8, 0.8 },  -- default x, y, width, height (tab fractions)
}
```

Scope determines which terminals share a set of nine slots:

- `session` (default): one set across all tabs; shells move to the tab invoking them.
- `tab`: one set per tab, shared by its panes.
- `pane`: one set per source pane.

Here, session `work` uses tab scope and `my-project` uses pane scope;
all others use session scope. Names are exact and case-sensitive. Omit `sessions`
to use `scope` everywhere. Keybindings are yours to change.

## Usage

Shortcuts are key sequences: press Ctrl+S, then the next key(s).

| Shortcut            | Action                                                         |
| ------------------- | -------------------------------------------------------------- |
| Ctrl+S, F           | Toggle slot 1, or the current slot when inside a RAFT terminal |
| Ctrl+S, Ctrl+F, 1–9 | Toggle a specific slot                                         |
| Ctrl+S, Q           | Hide the terminal                                              |
| Ctrl+S, Shift+F     | Open the manager                                               |

New shells inherit the source pane's directory when available. `exit` ends the
shell; toggling that slot again creates a new one. Changing scope preserves
existing shells; use the manager to find them.

Manager keys: `j`/`k` or arrows to select, Enter to open, `/` to search,
Ctrl+U to clear search while editing, `x` then `y` to close a shell,
`r` to refresh, Escape/`q` to quit browsing. Minimum size: 58×16.

Remote sessions run shells and the manager remotely. Install RAFT only on the
local Mac; no repo files or RAFT config are needed on the remote server.
Reopen the manager after config changes.

## Actions

Available after loading RAFT; bind with `rex.bind(key, action, args)`.

| Action        | Arguments             | Behavior                                                             |
| ------------- | --------------------- | -------------------------------------------------------------------- |
| `raft_toggle` | Optional `slot` (1–9) | Toggle a slot; defaults to the current RAFT slot or slot 1           |
| `raft_hide`   | Optional `slot` (1–9) | Hide the given slot or visible RAFT terminal; keep its shell running |
| `raft_manage` | None                  | Open or focus the manager                                            |
| `raft_list`   | None                  | Return all RAFT terminals in the current session                     |
| `raft_open`   | Required `block_id`   | Show an existing RAFT terminal without toggling it off               |
| `raft_close`  | Required `block_id`   | Immediately close a RAFT terminal and its running processes          |

```lua
rex.bind("ctrl+s>3", "raft_toggle", { slot = 3 })
```

CLI calls require RAFT in that server's config:

```sh
rex do raft_toggle slot=3
rex do raft_list --json
rex do raft_open block_id=block:ID
```

## Limits

- Keep a regular tiled pane open; splitting panes inside RAFT floats is unsupported.

[MIT](LICENSE).
