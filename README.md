# herdr-hg

A [herdr](https://herdr.dev) plugin that adds Mercurial support.

## Features

- **Worktrees for hg**: new, open, remove, clean up and close-group, using `hg share`
  checkouts and bookmarks. The same keys also drive git repos through herdr's own
  `herdr worktree`.
- **hg status in the sidebar**: active bookmark, unpushed (`↑`), incoming (`↓`) and changed
  (`*`) counts, and interrupted rebase/merge state, for every hg repo open in herdr.
- **Details popup**: everything the sidebar can't fit (parent commit, changed files, drafts,
  remote, shelves, other checkouts).
- **Automatic cleanup**: removing a share deletes the bookmark it created once its work has landed.
- **New-share bootstrap**: copies local files (`.env` etc.) and runs an optional setup script.
- **`hgwt` CLI**: `list`, `create`, `open`, `remove`, `prune`, `close-group`, `info`.

Full details: [docs/REFERENCE.md](docs/REFERENCE.md).

## Supported platforms

| Platform | Status |
|---|---|
| macOS | Supported (bash) |
| Linux | Supported (bash) |
| Windows | **In development**: a PowerShell port exists but has not been run on a real Windows machine yet |

## Install

Needs `herdr` ≥ 0.9 and `hg`. macOS and Linux also need `jq`, `nc` and `perl` (macOS ships
the last three). Windows needs nothing else.

```sh
herdr plugin install mpzarde/herdr-hg
```

Then run the setup action (herdr also prompts for it on first start):

```sh
herdr plugin action invoke mpzarde.hg-worktree.setup        # macOS / Linux
herdr plugin action invoke mpzarde.hg-worktree.setup-win    # Windows
```

Setup shows a diff and asks before changing anything. Undo it with `hgwt setup --uninstall`.
