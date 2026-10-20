# herdr-hg reference

Details behind the [README](../README.md): worktrees, cleanup, sidebar status, setup, CLI, configuration, limits.

## Worktrees

| | herdr + git | herdr-hg |
|---|---|---|
| New | `git worktree add` + workspace | `hg share -B`, then checks out an existing bookmark or named-branch head, or starts a new bookmark at the base revision. Opens it as a workspace (or opens the existing share). Copies local files and runs an optional setup script ([New shares](#new-shares)). |
| Open | worktree picker | Picks from the source repo and its shares (open ones marked) |
| Remove | `git worktree remove` | Deletes the checkout, closes its workspace, cleans up the bookmark ([Cleanup](#cleanup)). Unsaved files need typing `discard` (or `--force`). |
| Clean up | n/a | **prune**: removes closed shares and bookmarks whose work has landed |
| Close repo + worktrees | `workspace close --group` | **close-group**: closes the repo and all its shares, offering to prune first |
| Sidebar grouping | indented under parent | Shares labelled `↳ bookmark`, kept under the repo's workspace; `repo ▸ bookmark` when it isn't open |
| CLI | `herdr worktree ...` | `hgwt list/create/open/remove/prune/close-group`, with `--path`, `--label`, `--workspace` |
| Events | `worktree.*` | not emitted (herdr core only) |

herdr forgets plugin sidebar data and grouping on restart; the plugin restores both on startup.

### Where shares go

| `HG_WORKTREES_LAYOUT` | Path |
|---|---|
| `central` (default) | `~/.herdr/worktrees/<repo>/<bookmark>` |
| `sibling` | `<parent dir>/<repo>-<bookmark>` |

Shares are found in both locations whichever layout is set. `hgwt create --path DIR` puts one
anywhere; those are tracked in the source repo's `.hg/herdr-hg-shares`. Each share enables the
`share` extension in its own `.hg/hgrc`, so your global hgrc doesn't need it.

### Named branches

If the name is an existing named branch (not a bookmark), the share checks out its head and
creates no bookmark. Set `HG_NEW_BRANCH=branch` to start new work as named branches instead of
bookmarks. Cleanup never touches named branches; close them with `hg commit --close-branch`.

### New shares

A share starts with tracked files only. To bring local files (`.env`, local config), list globs
relative to the repo root in any of:

- `.hgwt-copy` in the repo (one per line, `#` comments; shared with your team)
- `.hg/hgwt-copy` (same format, just you)
- `HGWT_COPY` in config.env (space-separated, every repo)

Matches are copied if missing in the share; nothing is overwritten and patterns outside the repo
are skipped. Unchanged copies don't count as unsaved work on removal.

For anything else (deps, services), make `.hg/hgwt-setup` an executable script. It runs in the new
workspace's first pane with `HGWT_SOURCE` and `HGWT_SHARE` set. It only runs from `.hg/`, which
clones never contain, so a repo can't run code on your machine by itself. To use a committed
script, opt in per checkout: `ln -s ../.hgwt-setup .hg/hgwt-setup`.

## Cleanup

Finishing work should leave no checkout, stale bookmark or anonymous heads. A bookmark has
**landed** when every commit it holds is public, in another bookmark, or obsolete.

On **remove**, for a bookmark the plugin created:

| State | Result |
|---|---|
| landed | bookmark deleted |
| not landed (default) | bookmark kept so the work can be reopened; `prune` deletes it once it lands |
| not landed, `--strip` (or type `strip`) | bookmark and the commits only it holds are deleted (backup bundle in the source's `.hg/strip-backup`). Refused if another checkout is on them. |

Bookmarks the plugin didn't create (`main`, or ones you already had) are never deleted. Created
ones are listed in the source repo's `.hg/herdr-hg-bookmarks`.

**prune** removes closed shares with no unsaved files whose work has landed, plus created
bookmarks that no checkout uses and have landed, and lists any it keeps. **close-group** shows the
same list (open shares included) and asks first.

Deleting a bookmark locally doesn't delete it on the remote; run `hg push -B <bookmark>` after.

## Sidebar status

Two tokens for any workspace in an hg repo (share or not):

- `$hg_bookmark`: the active bookmark, else the branch
- `$hg_status`, combining:
  - `↑N` draft (unpublished) changesets in the working copy's ancestry
  - `↓N` incoming changesets for your bookmark/branch on `default`, checked in the background,
    cached (10 min) and rechecked after `hg pull`/`push`
  - `*N` modified, added, removed or missing files
  - `!op`, `!op:N` or `!N` (shown first): an interrupted rebase, merge, histedit, graft,
    unshelve, evolve or update, and/or N unresolved files

Setup adds both to the Space sidebar rows. Status refreshes after hg commands (`~/.hgrc` hooks),
when an agent finishes a turn, on workspace focus/create, and at startup. Manual refresh: the
**Refresh hg sidebar status** action or `hgwt refresh` (local counts; uses the cached `↓`).

### Long bookmark names

herdr cuts sidebar text at the end, losing the part that tells shares apart (a ticket number), so
the plugin shortens names itself, keeping start and end:
`Maint_2026.1100.100_CNRLWaterborne_39478112` → `Maint_…_39478112` at 16 characters. Only sidebar
text and share labels change, never the bookmark.

The length comes from `ui.sidebar_width` (26 if unset) minus room for `$hg_status` when it shares
the bookmark's row. A separate row or wider sidebar leaves more of the name. In config.env:

- `HG_BOOKMARK_STRIP`: extended regex removed first, e.g. `^Maint_[0-9.]+_` gives `CNRLWaterborne_39478112`
- `HG_BOOKMARK_MAX`: `auto` (default), a fixed length, or `0` for off

### Details popup

`prefix+shift+i` (or `hgwt info`) shows, for the current checkout:

- full bookmark (and whether hgwt made it / it landed), branch, other bookmarks and tags on the
  commit, topic, multiple-heads warning
- working copy parent (rev, hash, phase, message, author, date), its parent, and the second parent in a merge
- an interrupted rebase/merge/etc., its unresolved files and how to continue
- changed and untracked files, and the draft commits behind `↑`
- remote paths and the cached incoming check; `f` (or `hgwt info --fetch`) checks now and lists them
- shelves, and the repo's other checkouts

In a git repo it shows `git status -sb`, the last commit and the remotes.

## Install

Needs `herdr` ≥ 0.9, `hg`, `jq`, `nc` and `perl` (macOS ships the last three).

```sh
herdr plugin install mpzarde/herdr-hg
herdr plugin action invoke mpzarde.hg-worktree.setup   # or wait for the startup notification
./install.sh [--yes]                                   # alternative: from a local checkout
```

### What setup changes

Setup shows a diff and asks first. Each file is backed up to `*.herdr-hg.bak`, and everything
added sits between `herdr-hg` marker lines.

- `~/.config/herdr/config.toml`:
  - binds `prefix+shift+g` new, `+o` open, `+y` remove, `+c` close repo + shares, `+i` details.
    Clean up has no key; use the action list or `hgwt prune`.
  - moves herdr's git `new_worktree` to `prefix+alt+g` (Option on macOS must send Meta)
  - adds the two tokens to the Space sidebar rows (left alone, with a note, if you customised them)
  - runs `herdr config check`; if herdr rejects the result (e.g. a key clash), the backup is restored
- `~/.hgrc`: `update`, `txnclose` and `post-resolve` hooks (no-ops outside herdr). Rerun setup after
  an upgrade if `hgwt setup --status` fails.
- A hook helper in the plugin config dir, and an `hgwt` command in `~/.local/bin` if on PATH. Both
  look up the plugin location each time, so `herdr plugin update` doesn't break them. An existing
  `hgwt` that isn't ours is never overwritten.

```sh
hgwt setup --status      # exit 0 if set up
hgwt setup --uninstall   # remove everything setup added
hgwt setup --dismiss     # turn off the startup reminder
```

## Windows (in development)

**Work in progress.** A PowerShell port (`bin/hgwt.ps1`, `bin/hgwt-setup.ps1`) mirrors the bash
scripts. It was tested on macOS with PowerShell 7 against real hg repos (herdr stubbed) but
**never on Windows**. Expect rough edges and please report them.

- Needs only `herdr` and `hg` (`hg.exe` on PATH). Windows PowerShell 5.1 (built in) or 7.
- Install: `herdr plugin install mpzarde/herdr-hg` (or `herdr plugin link .`; `install.sh` is bash-only).
- herdr rejects duplicate ids, so Windows actions/panes carry a `-win` suffix. Run setup with
  `herdr plugin action invoke mpzarde.hg-worktree.setup-win`.
- Setup edits `%APPDATA%\herdr\config.toml` (or `HERDR_CONFIG_PATH`) and `%USERPROFILE%\.hgrc`,
  and adds `hgwt.cmd` to `%USERPROFILE%\.local\bin` if on PATH. Same backups and markers; keys bind
  to the `-win` actions. `config.env` lives in `%APPDATA%\herdr\plugins\config\mpzarde.hg-worktree`.
- Calls use `-ExecutionPolicy Bypass` (per process) because Windows blocks `.ps1` by default.
- Setup scripts: `.hg\hgwt-setup.ps1` (or `.cmd`/`.bat`) instead of the executable `.hg/hgwt-setup`.
- Unverified: the named-pipe call that orders share workspaces (failures are ignored), the
  `start /B` hg hook, and killing hg's process tree on timeout.

## CLI

hg repos only; for git use `herdr worktree`.

```sh
hgwt list [--json]                       # source repo + shares, with open workspace ids
hgwt create --bookmark feat-x [--base main] [--path DIR] [--label TEXT] [--no-focus]
hgwt open   --bookmark feat-x | --path DIR [--label TEXT] [--no-focus]
hgwt remove [--bookmark feat-x | --path DIR] [--force] [--strip]   # defaults to the current share
hgwt prune [--dry-run]
hgwt close-group [--prune]
hgwt info [--fetch]                      # what the details popup shows
```

All accept `--cwd DIR` or `--workspace ID` to pick the repo (default: current directory). A
`--label` is kept as is, never relabelled. `create` and `open` print `{"workspace_id": …, "path": …}`.

## Configuration

`$(herdr plugin config-dir mpzarde.hg-worktree)/config.env`. Rerun `hgwt setup` after changing keys.

```sh
HG_WORKTREES_LAYOUT=central             # or sibling
HG_WORKTREES_DIR=~/.herdr/worktrees     # root for the central layout
HG_SHARE_BOOKMARKS=1                    # share bookmarks with the source (hg share -B)
HG_NEW_BRANCH=bookmark                  # or branch: start new work as a named branch
HGWT_COPY=                              # globs to copy into new shares, e.g. ".env config/*.local"
HG_REMOTE_CHECK_MINUTES=10              # incoming check interval; 0 disables
HG_REMOTE_TIMEOUT=20                    # seconds before giving up on the remote
HGWT_HERDR_TIMEOUT=15                   # seconds before giving up on a herdr command
HGWT_HG_TIMEOUT=60                      # seconds for local hg calls in background refreshes
HG_BOOKMARK_MAX=auto                    # sidebar name length: auto, N, or 0 (off)
HG_BOOKMARK_STRIP=                      # regex removed from sidebar names, e.g. "^Maint_[0-9.]+_"
HGWT_KEY_NEW=prefix+shift+g
HGWT_KEY_OPEN=prefix+shift+o
HGWT_KEY_REMOVE=prefix+shift+y
HGWT_KEY_CLOSE_GROUP=prefix+shift+c
HGWT_KEY_INFO=prefix+shift+i
HGWT_KEY_GIT_NATIVE=prefix+alt+g
```

## Limits (herdr 0.9.5)

- Only herdr's git code can link workspaces as parent/child, so grouping is labels plus ordering. A
  share you drag elsewhere stays there until the repo's workspace opens/closes or herdr restarts.
- `worktree.*` events aren't emitted for hg shares.
- Editing files without running hg, with no agent turn finishing, updates `*N` on next focus.
- herdr has no sidebar hover or scrolling; long names are shortened and the details popup has the rest.
- herdr sends no event on `cd`, so hg status is stale after entering/leaving a repo until the next
  refresh (focus, hg command, agent turn, or the Refresh action). Setup doesn't hook your shell rc.
- The incoming check uses your normal hg auth but never prompts; password-prompt remotes show no `↓`.
- The setup script is typed into the new workspace's shell, so it needs a shell prompt (the default).
- TortoiseHg's settings dialog rewrites `~/.hgrc`; if the hooks vanish, rerun `hgwt setup`.

Development status, next steps and design notes: [NOTES.md](NOTES.md).
