# herdr-hg

A [herdr](https://herdr.dev) plugin that gives Mercurial repos the same worktree
workflow herdr has for git, using `hg share` checkouts and bookmarks.

herdr itself still only knows about git. This plugin checks which kind of repo
you're in, so the same keys work in both: hg repos get `hg share`, git repos are
handed to herdr's built-in `herdr worktree`.

## Features

| | herdr + git | herdr-hg |
|---|---|---|
| New worktree | `git worktree add` + workspace | `hg share -B`, update to base, create/activate bookmark, open workspace. If the share already exists, it opens it. |
| Open | worktree picker | Picks from the source repo and its shares (marks which are open) and switches to or opens one |
| Remove | `git worktree remove`, keeps branch | Closes the workspace and deletes the checkout. Commits and bookmarks stay in the repo. Uncommitted changes need typing `discard` (or `--force`). |
| Close repo + worktrees | `workspace close --group` | **close-group**: closes the repo's workspace and all its share workspaces |
| Sidebar grouping | shares indented under parent | Shares are labelled `↳ bookmark` and kept directly under the repo's workspace. When the repo's workspace isn't open they read `repo ▸ bookmark`. |
| Sidebar status | `branch` · `git_status` (ahead/behind) | `$hg_bookmark` · `$hg_status` |
| CLI | `herdr worktree list/create/open/remove` | `hgwt list/create/open/remove/close-group` |
| Events | `worktree.*` | not emitted (herdr core only) |

`$hg_status` combines:

- `↑N`: draft (unpublished) changesets in your working copy's ancestry
- `↓N`: incoming changesets for your bookmark (or branch) on the `default` remote.
  This is checked in the background and cached (10 min by default), and re-checked
  straight after `hg pull`/`push`.
- `*N`: modified, added, removed or missing files

The status refreshes after hg commands (via `~/.hgrc` hooks), when an agent in
the workspace finishes a turn, when a workspace is focused or created, and on
herdr startup.

### Where shares go

| `HG_WORKTREES_LAYOUT` | Path |
|---|---|
| `central` (default, same as herdr's git worktrees) | `~/.herdr/worktrees/<repo>/<bookmark>` |
| `sibling` | next to the repo: `<parent dir>/<repo>-<bookmark>` |

Shares are found in both locations whichever layout is set, so changing it later
doesn't lose track of existing ones. Each share enables the `share` extension in
its own `.hg/hgrc` so shared bookmarks resolve; your global hgrc doesn't need it.

## Install

Needs `herdr` ≥ 0.9, `hg`, `jq`, `nc` and `perl` (macOS ships the last three).

**From GitHub** (once published):

```sh
herdr plugin install <owner>/herdr-hg
```

The first time herdr starts after that, a notification points you at the
**Set up hg worktrees** action. You can also run it straight away:

```sh
herdr plugin action invoke mpzarde.hg-worktree.setup
```

**From a local checkout:**

```sh
./install.sh            # links the plugin, shows the config diff, asks before applying
./install.sh --yes      # same, no prompt
```

### What setup changes

Setup shows a diff and asks before changing anything. It backs up each file to
`*.herdr-hg.bak`, and everything it adds sits between `herdr-hg` marker lines.

- `~/.config/herdr/config.toml`
  - binds `prefix+shift+g` new · `prefix+shift+o` open · `prefix+shift+y` remove ·
    `prefix+shift+c` close repo + shares (prefix is `ctrl+b` unless you changed it)
  - moves herdr's built-in git `new_worktree` to `prefix+alt+g` (Option on macOS;
    your terminal must send Option as Meta)
  - adds `$hg_bookmark` and `$hg_status` to the Space sidebar rows. If you've
    already customised those rows, setup leaves them alone and tells you what to add.
  - runs `herdr config check` on the result. If herdr rejects it (a key clash,
    for example), the backup is restored.
- `~/.hgrc`: `update` and `txnclose` hooks. Outside herdr they do nothing.
- A hook helper script in the plugin config dir, and an `hgwt` command in
  `~/.local/bin` if that's on your PATH. Both look up the plugin's current
  location each time, so `herdr plugin update` doesn't break them. Setup won't
  overwrite an `hgwt` it didn't create.

```sh
hgwt setup --status      # exit 0 if set up
hgwt setup --uninstall   # remove everything setup added
hgwt setup --dismiss     # turn off the startup reminder
```

## CLI

The CLI works on hg repos only. For git, use `herdr worktree`.

```sh
hgwt list [--json]                       # source repo + shares, with open workspace ids
hgwt create --bookmark feat-x [--base main] [--no-focus]
hgwt open   --bookmark feat-x | --path DIR [--no-focus]
hgwt remove [--bookmark feat-x | --path DIR] [--force]   # defaults to the share you're in
hgwt close-group
```

All of these accept `--cwd DIR` (default: current directory). `create` and `open`
print `{"workspace_id": …, "path": …}`.

## Configuration

`$(herdr plugin config-dir mpzarde.hg-worktree)/config.env`. Rerun `hgwt setup`
after changing keys:

```sh
HG_WORKTREES_LAYOUT=central             # or sibling
HG_WORKTREES_DIR=~/.herdr/worktrees     # root for the central layout
HG_SHARE_BOOKMARKS=1                    # share bookmarks with the source (hg share -B)
HG_REMOTE_CHECK_MINUTES=10              # incoming check interval; 0 disables
HG_REMOTE_TIMEOUT=20                    # seconds before giving up on the remote
HGWT_KEY_NEW=prefix+shift+g
HGWT_KEY_OPEN=prefix+shift+o
HGWT_KEY_REMOVE=prefix+shift+y
HGWT_KEY_CLOSE_GROUP=prefix+shift+c
HGWT_KEY_GIT_NATIVE=prefix+alt+g
```

## Limits (herdr 0.9.5)

- Only herdr's git code can set up a real parent/child link between workspaces,
  so the grouping is labels plus ordering. If you drag a share elsewhere it stays
  there until the repo's workspace is next opened or closed, or herdr restarts.
- `worktree.created/opened/removed` events aren't emitted for hg shares.
- If you edit files without running hg and no agent finishes a turn, `*N` updates
  the next time you focus the workspace.
- The incoming check uses your normal hg auth but never prompts. Remotes that
  need a password prompt simply show no `↓`.
- macOS and Linux only (bash scripts).
- TortoiseHg's settings dialog rewrites `~/.hgrc`. If the hooks disappear after
  you use it, run `hgwt setup` again.
