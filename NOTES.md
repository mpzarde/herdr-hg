# Development notes

Working notes for herdr-hg: status, next steps, design decisions and the herdr
quirks found while building it. User-facing docs are in [README.md](README.md).

## Status (2026-10-16, v0.5.0, herdr 0.9.5, hg 7.0.2)

- Linked locally: `herdr plugin link ~/projects/herdr-hg`
- Setup applied on the author's machine (`hgwt setup`). The plugin's `config.env`
  sets `HG_WORKTREES_LAYOUT=sibling`.
- Everything below "Tested" was scripted against throwaway repos. The popups
  have **not** been driven by hand inside herdr yet.

### Tested (scripted)

- create/open/remove/close-group via CLI and via popup bodies (piped input)
- both layouts (central + sibling); discovery across both; creating an existing
  share reopens it
- `↳` labels; relabel to `repo ▸ bm` when the source closes, and back when it reopens
- regroup: shares opened before the source move under it when it opens
- `↑` draft, `↓` incoming (local upstream clone), `*` dirty counts
- `~/.hgrc` hook → refreshes the workspace that has the repo open (not the
  caller's `$HERDR_WORKSPACE_ID`)
- `pane.agent_status_changed` (simulated), `workspace.created/closed` event hooks
  (real herdr events)
- removal guards: dirty share or untracked files need `--force`/`discard`; refuses
  the source repo and non-shares
- cleanup (v0.3): remove deletes a created bookmark once landed (pushed/public, or
  another bookmark moved onto it), keeps it when not landed, `--strip` deletes it
  plus its commits with the backup in the source repo; strip refused when another
  checkout is on those commits; `main`/pre-existing bookmarks never deleted;
  `prune` (dry-run, orphan bookmarks, open shares skipped); `close-group --prune`;
  remove/strip/prune popups via piped input; remote cache dir removed with the share
- v0.4: copy globs (incl. dirs, outside-repo patterns skipped, no overwrite); setup
  script runs in the new workspace's pane; unchanged copies don't block remove,
  edited ones do; `!rebase:N` / `!rebase` / `!merge:N` / cleared after abort;
  existing named branch checkout; `HG_NEW_BRANCH=branch`; `--path` share found by
  list/re-create, unrecorded on remove; `--label`; `--workspace`; setup adds
  `post-resolve` and `--status` fails on an outdated hgrc block
- v0.5: sidebar names shortened head…tail to a row-aware budget, `HG_BOOKMARK_STRIP`,
  `HG_BOOKMARK_MAX=0`; share labels shortened too; `hgwt info` / `--fetch` (incoming
  list) and the popup (enter, `f`, git fallback); zsh `chpwd` hook clears tokens
  after `cd ~` in a live pane; bash `PROMPT_COMMAND` hook fires only on change;
  rc uninstall byte-identical; `prefix+shift+i` passes `herdr config check`
- setup: idempotent rerun, byte-for-byte uninstall, existing `[keys]` table,
  customised sidebar rows left alone, key clash → rollback, foreign `hgwt` on
  PATH left alone

## Next steps

1. **Manual test in a real hg repo**: `ctrl+b G` / `O` / `Y` / `C` popups and the
   Clean up action, sizes, prompts, focus behaviour. In particular:
   - removing the share you're in from its own popup (the workspace close may
     kill the popup; all hg work is done before that, but its messages may not
     be visible)
   - `↓` against a real (ssh/https) remote, including the timeout and no-prompt
     behaviour
   - v0.4: `.hg/hgwt-setup` running in the new pane (shell prompt ready in time?),
     `!` status during a real rebase/merge, the setup reminder on an outdated
     hgrc block, and the New popup with a named branch
   - v0.5: `prefix+shift+i` popup size and paging (`less` when it doesn't fit),
     whether the auto name budget matches what herdr actually shows at your
     sidebar width and indent (shares are indented further), and `cd` in a
     pane that isn't the workspace's focused one
2. **Publish**: create a GitHub repo, push, add the `herdr-plugin` topic (shows up
   in herdr's marketplace, which re-indexes every 30 min). Then replace `<owner>`
   in README. Not done yet: needs the account/org and public/private decision.
3. **Test the GitHub install path**: `herdr plugin install <owner>/herdr-hg` on a
   clean machine/user. Check the startup nudge notification fires, the setup
   action popup works, and the hook/CLI shims survive `herdr plugin update`
   (managed install dirs change on update).
4. **Upstream feature request to herdr**: let plugins attach worktree provenance
   (e.g. a `parent_workspace_id`/group param on `workspace.create`, or
   `workspace.set_group`). That would give real nesting, `close --group` and
   `worktree.*` events, and remove the label/ordering workaround. Draft not
   written yet.
5. **Sync / land actions** (discussed, not started): "sync" = pull + rebase the
   share's bookmark onto upstream (or update); "land" = push `-B` then offer prune.
   Needs decisions: rebase vs merge, which remote, what to do with named branches.
6. Possible extras, not started:
   - fuzzy picker when `fzf` is installed (currently a numbered list)
   - a key binding for Clean up (any version that needs a setup rerun could add it)
   - topics (evolve) as an alternative to bookmarks; unstable-commit count in status
   - shelve count in status
   - a test script in-repo (tests so far were ad-hoc shell; see "Testing" below)
   - Windows support (herdr supports it; this plugin is bash-only)

## Design decisions

- **hg share, not clones**: shares one store, so commits made in any share are
  instantly visible everywhere, and deleting a share loses only uncommitted work.
  Same model as `git worktree`.
- **Bookmarks stand in for branches** (`hg share -B` so bookmarks are shared).
  Named branches are permanent in hg, so they're a poor match for throwaway
  worktree branches. Existing named branches are still checked out when named,
  and `HG_NEW_BRANCH=branch` is there for teams that work that way; cleanup
  leaves named branches alone.
- **Two kinds of hg state are never touched by cleanup**: named branches and
  bookmarks the plugin didn't create.
- **Discovery by scanning, minimal state**: shares are found by scanning both
  layout locations and checking `.hg/sharedpath` → source, so changing layout
  never orphans anything. The little state there is lives inside `.hg/` and goes
  away with the repo or share; list files are deleted when they empty:
  - `<source>/.hg/herdr-hg-bookmarks`: bookmarks `hgwt create` made
  - `<source>/.hg/herdr-hg-shares`: shares created with `--path`
  - `<share>/.hg/hgwt-copied`: files bootstrap copied in
  - `<share>/.hg/hgwt-setup-pending`: setup script still to run (create → open)
  - the incoming cache, `$XDG_CACHE_HOME/herdr-hg/remote/<checkout>/`, removed
    with the share
- **Clean up only what we made**: only bookmarks listed in
  `herdr-hg-bookmarks` get deleted.
  "Landed" = `only(B, public() or <other bookmarks>) - obsolete()` is empty. Not
  landed means keep (default) or strip (explicit), never delete the bookmark and
  leave anonymous heads behind. If hg can't evaluate it, treat it as not landed.
- **Repo-provided code never runs by itself**: `.hgwt-copy` (data) is read from
  the working copy, but the setup script only from `.hg/`, which clones don't
  carry. Opting in to a committed script is a symlink.
- **Setup script runs in the workspace pane**, not the popup: its output stays
  visible and long installs don't block the popup or CLI. A
  `.hg/hgwt-setup-pending` marker carries it from create to open, since
  create runs in a `$(…)` subshell.
- **Labels decide grouping**: `↳ x` / `repo ▸ x` labels are "generated". Only
  generated labels are rewritten, so a manual rename opts a workspace out.
- **Regroup only on create/open/source open/close/startup**, not on every focus,
  so dragging a share elsewhere isn't immediately undone.
- **Remote checks never block UI**: popups/CLI use cache only; network happens in
  event hooks (async from herdr's side) and backgrounded hg hooks.
- **Git is delegated, not reimplemented**: the plugin's keys call
  `herdr worktree …` in git repos so herdr keeps its real provenance/nesting.
- **Names are shortened in the plugin**: herdr has no hover/marquee and cuts at
  the end. Head…tail (2:3) keeps ticket numbers. The budget is a guess from
  `ui.sidebar_width` and whether `$hg_status` shares the row; herdr auto-scales
  the width from workspace names, so it can be wider than we assume (we then
  just show less than we could), never narrower than configured.
- **A shell hook for `cd`**: herdr emits nothing when a pane's cwd changes
  (checked: no `workspace.updated`/`renamed` or `pane.updated`), though it
  relabels the workspace. The hook passes `$PWD` because herdr may not have seen
  the new cwd yet; it's only used when that pane is the one the sidebar follows.
- **Setup is fenced**: everything added lives between `herdr-hg` markers (or
  lines tagged `# herdr-hg`), validated with `herdr config check`, with rollback.

## herdr / hg gotchas found

- `workspace.move` `insert_index` = "insert **before** the workspace currently at
  this index" (pre-removal indexing), not "final position". No CLI for it, so
  it's a raw socket call (`nc -U $HERDR_SOCKET_PATH`, one JSON line, `params`
  required even when empty).
- Plugin event hooks with a non-zero exit show as `failed` in
  `herdr plugin log list`. Under `set -e`, a trailing `cond && action` returns 1
  when `cond` is false, so use `if` instead.
- Popups: stdin is the popup terminal, but pickers read from a pipe, so the script
  saves the terminal as fd 3 (`exec 3<&0`). Prompts must go to stderr or they
  end up in `$(…)` captures.
- `HERDR_PLUGIN_CONTEXT_JSON` has `focused_pane_cwd` / `workspace_cwd`; workspace
  records themselves don't have a cwd, so derive it from `herdr pane list`.
- Workspace metadata tokens aren't persisted across herdr restarts, hence the
  startup hook.
- `herdr config check` honours `XDG_CONFIG_HOME` (handy for sandbox tests);
  `herdr server reload-config` always hits the running server.
- hg: shared bookmarks only resolve when the `share` extension is loaded for
  every command. Without it, `hg bookmarks` in the share shows "no bookmarks set".
  Fixed per share via `.hg/hgrc`.
- hg `incoming` exits 1 for "nothing incoming" (not an error). Anything above 1
  means error/unknown bookmark, so fall back to `-b <branch>`.
- hg 7: `strip` is core as `hg debugstrip` (the extension is deprecated). Run it
  from the source repo, not the share being removed, or the backup bundle lands
  in the share's `.hg` and gets deleted with it.
- Shares made without `-B` don't see the source's bookmarks, so a revset naming a
  bookmark errors there (and an empty result looks like "nothing"). Compare by
  node in a repo that does see it.
- The `update` hook fires (with `HG_ERROR` = unresolved count) when a merge or
  rebase stops on conflicts, so `!` shows up without extra hooks. `hg resolve -m`
  fires nothing, hence `post-resolve`.
- `branch('X')` falls back to resolving X as a revision (`branch('bm')` = the
  bookmark's branch). Use `branch('literal:X')`. `{branch}` of `.` is the
  committed parent's branch; a pending `hg branch` only shows in `hg branch`.
- Remote bookmarks: delete locally, then `hg push -B name` deletes it remotely.
- bash 3.2 treats UTF-8 bytes after `$name` as part of the name: `"$label…"`
  is the unbound variable `label…`. Brace it: `"${label}…"`.
- Don't redirect `less`'s stdin to the terminal (`<&3`); it reads keys from
  `/dev/tty` and the text from the pipe.
- macOS: bash 3.2 (`source <(…)` doesn't work, no `mapfile`/assoc arrays), no
  `timeout` (use `perl -e 'alarm …; exec …'`), BSD `sed -i ''`.

## Testing

No test suite yet. What was used:

```sh
S=$(mktemp -d)
hg init $S/upstream && (cd $S/upstream && echo a > a && hg add -q a && hg ci -qm init -u t && hg bookmark main)
hg clone -q $S/upstream $S/demo && (cd $S/upstream && echo b >> a && hg ci -qm up -u t)   # → ↓1
export XDG_CACHE_HOME=$S/cache HG_WORKTREES_DIR=$S/wt HG_WORKTREES_LAYOUT=sibling HGWT_FOCUS=0
cd $S/demo && hgwt open --path . --no-focus && hgwt create --bookmark feat-a --no-focus
herdr workspace list | jq -c '[.result.workspaces[] | "\(.label)=\(.tokens.hg_status // "")"]'
# popups: pipe answers and fake the context
printf 'feat-b\n.\n' | HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_cwd\":\"$S/demo\"}" bin/hgwt ui new
# setup in a sandbox
XDG_CONFIG_HOME=$S/x HGRCPATH_USER=$S/hgrc HERDR_PLUGIN_CONFIG_DIR=$S/pc HGWT_BIN_DIR=$S/bin \
  HGWT_SHELL=zsh HGWT_SHELL_RC=$S/zshrc bin/hgwt-setup --yes
```

Every `hgwt-setup` call in a test needs those variables. One call without them
(say, a `--uninstall` to reset first) acts on your real `~/.hgrc` and herdr
config; that happened once during v0.4 testing and was restored from the
`.herdr-hg.bak` files.

Clean up the test workspaces afterwards (`hgwt close-group` from the test repo).
`HGWT_FOCUS=0` keeps tests from stealing focus from your current pane.
