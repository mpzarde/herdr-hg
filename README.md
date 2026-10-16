# herdr-hg

A [herdr](https://herdr.dev) plugin that gives Mercurial repos the same worktree
workflow herdr has for git, using `hg share` checkouts and bookmarks.

| herdr + git | herdr-hg |
|---|---|
| `worktree create` → `git worktree add` + workspace | **new**: `hg share -B`, update to base, create/activate bookmark, open workspace |
| `worktree open` | **open**: pick from the source repo and its shares; focuses if already open |
| `worktree remove` (keeps branch) | **remove**: closes workspace, deletes the share checkout; commits and bookmarks stay in the source repo. Uncommitted changes need typing `discard`. |
| sidebar `branch` · `git_status` | `$hg_bookmark` · `$hg_status` (`↑N` draft changesets, `*N` modified files) |
| worktree grouping in sidebar | approximated: shares are labelled `repo ▸ bookmark` and placed right after the source workspace |

All three actions also work in git repos and hand off to herdr's built-in
`herdr worktree …`, so one set of keys covers both.

Shares live in `~/.herdr/worktrees/<repo>/<bookmark-slug>`, the same root herdr uses
for git. Each share enables the `share` extension in its own `.hg/hgrc` so shared
bookmarks resolve; your global hgrc doesn't need it.

## Install

Needs `herdr` ≥ 0.9, `hg`, `jq` and `nc` (macOS ships the last two).

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
  - binds `prefix+shift+g` new · `prefix+shift+o` open · `prefix+shift+y` remove
  - moves herdr's built-in git `new_worktree` to `prefix+alt+g`
  - adds `$hg_bookmark` and `$hg_status` to the Space sidebar rows. If you've
    already customised those rows, setup leaves them alone and tells you what to add.
  - runs `herdr config check` on the result. If herdr rejects it (a key clash,
    for example), the backup is restored.
- `~/.hgrc`: `update` and `txnclose` hooks, so the sidebar updates right after
  commits, updates and bookmark changes. Outside herdr they do nothing.
- A small hook helper script in the plugin config dir. It looks up the plugin's
  current location each time, so `herdr plugin update` doesn't break the hooks.

Other commands:

```sh
bin/hgwt setup --status      # exit 0 if set up
bin/hgwt setup --uninstall   # remove everything setup added
bin/hgwt setup --dismiss     # turn off the startup reminder
```

### Choosing other keys

Put overrides in `$(herdr plugin config-dir mpzarde.hg-worktree)/config.env` and
run setup again:

```sh
HGWT_KEY_NEW=prefix+shift+g
HGWT_KEY_OPEN=prefix+shift+o
HGWT_KEY_REMOVE=prefix+shift+y
HGWT_KEY_GIT_NATIVE=prefix+alt+g
HG_WORKTREES_DIR=~/.herdr/worktrees   # where shares go
HG_SHARE_BOOKMARKS=1                  # share bookmarks with the source (hg share -B)
```

## Limits (herdr 0.9.5)

- herdr's native worktree link (indented sidebar nesting, `workspace close --group`)
  can only be set by its git code, so hg shares are siblings, not children.
- `worktree.created/opened/removed` events aren't emitted for hg shares.
- macOS and Linux only (bash scripts).
- TortoiseHg's settings dialog rewrites `~/.hgrc`. If the hooks disappear after
  you use it, run setup again.
