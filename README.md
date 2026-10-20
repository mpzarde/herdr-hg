# herdr-hg

A [herdr](https://herdr.dev) plugin that adds Mercurial support to herdr. It
does two things:

- **Worktrees for hg**: the same worktree workflow herdr has for git, using
  `hg share` checkouts and bookmarks.
- **hg status in the sidebar**: bookmark, unpushed/incoming counts and changed
  files for every hg repo open in herdr, whether or not you use shares, plus a
  details popup for everything the sidebar can't fit.

> **Platform support: \*nix only (macOS and Linux).** The plugin is written in bash
> and does not run on Windows. Installing it there fails with
> `platform_unsupported`.

herdr itself still only knows about git. This plugin checks which kind of repo
you're in, so the same keys work in both: hg repos get `hg share`, git repos are
handed to herdr's built-in `herdr worktree`.

## Worktrees

| | herdr + git | herdr-hg |
|---|---|---|
| New worktree | `git worktree add` + workspace | `hg share -B`, then checks out an existing bookmark, or the head of an existing named branch, or starts a new bookmark at the base revision. Opens it as a workspace; if the share already exists, it opens that. Copies your untracked local files and runs an optional setup script (see [New shares](#new-shares)). |
| Open | worktree picker | Picks from the source repo and its shares (marks which are open) and switches to or opens one |
| Remove | `git worktree remove`, keeps branch | Deletes the checkout and closes its workspace, and cleans up the bookmark (see [Cleanup](#cleanup)). Uncommitted changes or untracked files need typing `discard` (or `--force`). |
| Clean up | — | **prune**: removes closed shares and bookmarks whose work has landed |
| Close repo + worktrees | `workspace close --group` | **close-group**: closes the repo's workspace and all its share workspaces, offering to prune first |
| Sidebar grouping | shares indented under parent | Shares are labelled `↳ bookmark` and kept directly under the repo's workspace. When the repo's workspace isn't open they read `repo ▸ bookmark`. |
| CLI | `herdr worktree list/create/open/remove` | `hgwt list/create/open/remove/prune/close-group`, with `--path`, `--label`, `--workspace` like herdr's |
| Events | `worktree.*` | not emitted (herdr core only) |

herdr forgets plugin sidebar data and the share grouping when it restarts, so
the plugin restores both on startup.

### Where shares go

| `HG_WORKTREES_LAYOUT` | Path |
|---|---|
| `central` (default, same as herdr's git worktrees) | `~/.herdr/worktrees/<repo>/<bookmark>` |
| `sibling` | next to the repo: `<parent dir>/<repo>-<bookmark>` |

Shares are found in both locations whichever layout is set, so changing it later
doesn't lose track of existing ones. `hgwt create --path DIR` puts a share
anywhere else; those are listed in the source repo's `.hg/herdr-hg-shares` so
they're still found (the entry goes when the share is removed).

Each share enables the `share` extension in its own `.hg/hgrc` so shared
bookmarks resolve; your global hgrc doesn't need it.

### Named branches

If the name you enter is an existing named branch (and not a bookmark), the
share checks out that branch's head and no bookmark is created. To start new work
as named branches instead of bookmarks, set `HG_NEW_BRANCH=branch`: the share
runs `hg branch NAME` at the base revision. Cleanup never deletes or closes named
branches; close a finished one with `hg commit --close-branch` as usual.

### New shares

A share starts with only tracked files. To bring local files along (`.env`,
local config), list glob patterns, relative to the repo root, in any of:

- `.hgwt-copy` in the repo (one per line, `#` comments), to share with your team
- `.hg/hgwt-copy` (same format, just for you)
- `HGWT_COPY` in config.env (space-separated, applies to every repo)

Matches are copied from the source checkout if they don't already exist in the
share. Nothing is overwritten, and patterns outside the repo are skipped. Copies
that you haven't changed don't count as unsaved work when the share is removed.

For anything else (installing dependencies, starting services), make
`.hg/hgwt-setup` an executable script. It runs in the new workspace's first pane,
so you see its output, with `HGWT_SOURCE` and `HGWT_SHARE` set. It only runs from
`.hg/`, which clones never contain, so a repo can't run code on your machine by
itself. To use a script committed to the repo, opt in per checkout with
`ln -s ../.hgwt-setup .hg/hgwt-setup`.

## Cleanup

The goal is that finishing a piece of work leaves nothing behind: no checkout,
no stale bookmark, no anonymous heads.

A bookmark's work has **landed** when every commit it holds is public (pushed),
also in another bookmark (e.g. `main` was moved or merged onto it), or obsolete
(rebased/landed elsewhere with evolve).

On **remove**, for a bookmark the plugin created:

| State | What happens |
|---|---|
| landed | the bookmark is deleted |
| not landed (default) | the bookmark is kept, so the work is still there to reopen; `prune` deletes it once it lands |
| not landed, `--strip` (or type `strip` in the popup) | the bookmark and the commits only it holds are deleted. hg keeps a backup bundle in the source repo's `.hg/strip-backup`. Refused if another checkout is on those commits |

Bookmarks the plugin didn't create (`main`, or one you already had and opened a
share for) are never deleted. Created bookmarks are listed in the source repo's
`.hg/herdr-hg-bookmarks`; the file goes away when the list is empty. Shares
created before v0.3 aren't listed, so their bookmarks are kept.

**prune** removes shares that are closed in herdr, have no uncommitted or
untracked files (unchanged [copies](#new-shares) don't count), and whose work
has landed. It also deletes created bookmarks
that no checkout uses and that have landed, and lists any it keeps.
**close-group** shows the same list (open shares included, since they're about
to close) and asks before pruning.

Deleting a local bookmark doesn't delete it on the remote. If you pushed it
with `-B`, run `hg push -B <bookmark>` after it's deleted locally; that deletes
it on the remote too.

## Sidebar status

herdr shows `branch` and `git_status` for git repos and nothing for hg. This
plugin adds two sidebar tokens for any workspace whose directory is in an hg
repo (a share or not):

- `$hg_bookmark`: the active bookmark, or the branch if no bookmark is active
- `$hg_status`, which combines:
  - `↑N`: draft (unpublished) changesets in your working copy's ancestry
  - `↓N`: incoming changesets for your bookmark (or branch) on the `default`
    remote. This is checked in the background and cached (10 min by default),
    and re-checked straight after `hg pull`/`push`.
  - `*N`: modified, added, removed or missing files
  - `!op`, `!op:N` or `!N`, shown first: an interrupted rebase, merge, histedit,
    graft, unshelve, evolve or update, and/or N files with unresolved conflicts.
    This is the state an agent gets stuck in.

Setup adds both tokens to the Space sidebar rows. The status refreshes after hg
commands (via `~/.hgrc` hooks), when an agent in the workspace finishes a turn,
when a workspace is focused or created, and on herdr startup. To refresh by hand,
run the **Refresh hg sidebar status** action (`hgwt refresh`); it rereads the
local counts and uses the cached `↓`.

### Long bookmark names

herdr cuts sidebar text off at the end, which loses the part of a bookmark that
usually tells shares apart, like a ticket number. So the plugin shortens names
itself, keeping the start and the end:
`Maint_2026.1100.100_CNRLWaterborne_39478112` → `Maint_…_39478112` at 16 characters. Only the sidebar
text and share labels change, never the bookmark.

The length comes from `ui.sidebar_width` in your herdr config (26 if unset),
minus room for `$hg_status` when it shares the bookmark's row. Setup puts them on
one row; giving `$hg_bookmark` a row of its own, or widening the sidebar, leaves
more of the name. Settings in config.env:

- `HG_BOOKMARK_STRIP`: an extended regex removed from names before shortening,
  e.g. `^Maint_[0-9.]+_` turns the example into `CNRLWaterborne_39478112`
- `HG_BOOKMARK_MAX`: `auto` (default), a fixed length, or `0` to turn it off

### Details popup

`prefix+shift+i` (or `hgwt info`) shows everything for the checkout you're in:

- the full bookmark (and whether hgwt made it and it has landed), branch, other
  bookmarks and tags on the same commit, topic, and a warning for multiple heads
- the working copy parent (rev, hash, phase, message, author, date), its parent,
  and the second parent during a merge
- an interrupted rebase/merge/etc., its unresolved files and how to continue
- changed and untracked files, and the unpushed draft commits behind `↑`
- remote paths and the cached incoming check; press `f` (or
  `hgwt info --fetch`) to check now and list the incoming commits
- shelves, and the repo's other checkouts (which are open in herdr)

In a git repo it shows `git status -sb`, the last commit and the remotes.

## Install

**\*nix only (macOS and Linux); Windows is not supported** (see Limitations).

Needs `herdr` ≥ 0.9, `hg`, `jq`, `nc` and `perl` (macOS ships the last three).

**From GitHub:**

```sh
herdr plugin install mpzarde/herdr-hg
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
    `prefix+shift+c` close repo + shares · `prefix+shift+i` details (prefix is
    `ctrl+b` unless you changed it).
    **Clean up** has no key; run it from herdr's action list or `hgwt prune`.
  - moves herdr's built-in git `new_worktree` to `prefix+alt+g` (Option on macOS;
    your terminal must send Option as Meta)
  - adds `$hg_bookmark` and `$hg_status` to the Space sidebar rows. If you've
    already customised those rows, setup leaves them alone and tells you what to add.
  - runs `herdr config check` on the result. If herdr rejects it (a key clash,
    for example), the backup is restored.
- `~/.hgrc`: `update`, `txnclose` and `post-resolve` hooks. Outside herdr they do nothing.
- After upgrading the plugin, `hgwt setup --status` fails until you rerun setup if
  the hooks changed.
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
hgwt create --bookmark feat-x [--base main] [--path DIR] [--label TEXT] [--no-focus]
hgwt open   --bookmark feat-x | --path DIR [--label TEXT] [--no-focus]
hgwt remove [--bookmark feat-x | --path DIR] [--force] [--strip]   # defaults to the share you're in
hgwt prune [--dry-run]
hgwt close-group [--prune]
hgwt info [--fetch]                      # what the details popup shows
```

All of these accept `--cwd DIR` or `--workspace ID` to pick the repo (default:
current directory). A `--label` is kept as is: the plugin doesn't relabel it
when the source repo opens or closes. `create` and `open`
print `{"workspace_id": …, "path": …}`.

## Configuration

`$(herdr plugin config-dir mpzarde.hg-worktree)/config.env`. Rerun `hgwt setup`
after changing keys:

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

- Only herdr's git code can set up a real parent/child link between workspaces,
  so the grouping is labels plus ordering. If you drag a share elsewhere it stays
  there until the repo's workspace is next opened or closed, or herdr restarts.
- `worktree.created/opened/removed` events aren't emitted for hg shares.
- If you edit files without running hg and no agent finishes a turn, `*N` updates
  the next time you focus the workspace.
- No hover or scrolling for sidebar text in herdr; long names are shortened (see
  [Long bookmark names](#long-bookmark-names)) and the details popup has the rest.
- herdr sends no event when a pane changes directory, so after a `cd` into or
  out of a repo the hg status is stale until the next refresh (focusing the
  workspace, an hg command, an agent finishing a turn, or the Refresh action).
  Setup deliberately doesn't hook your shell rc to catch it.
- The incoming check uses your normal hg auth but never prompts. Remotes that
  need a password prompt simply show no `↓`.
- The setup script is typed into the new workspace's shell, so it needs a shell
  prompt there (the default).
- \*nix only: macOS and Linux (bash scripts). Windows is not supported and fails
  with `platform_unsupported`; a port is listed in NOTES.md.
- TortoiseHg's settings dialog rewrites `~/.hgrc`. If the hooks disappear after
  you use it, run `hgwt setup` again.

Development status, next steps and design notes: [NOTES.md](NOTES.md).
