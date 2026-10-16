# Development notes

Working notes for herdr-hg: status, next steps, design decisions and the herdr
quirks found while building it. User-facing docs are in [README.md](README.md).

## Status (2026-10-16, v0.2.0, herdr 0.9.5, hg 7.0.2)

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
- removal guards: dirty share needs `--force`/`discard`; refuses the source repo
  and non-shares; bookmarks survive removal
- setup: idempotent rerun, byte-for-byte uninstall, existing `[keys]` table,
  customised sidebar rows left alone, key clash → rollback, foreign `hgwt` on
  PATH left alone

## Next steps

1. **Manual test in a real hg repo**: `ctrl+b G` / `O` / `Y` / `C` popups, sizes,
   prompts, focus behaviour. Check `↓` against a real (ssh/https) remote,
   including the timeout and no-prompt behaviour.
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
5. Possible extras, not started:
   - fuzzy picker when `fzf` is installed (currently a numbered list)
   - `hgwt prune`: find shares whose bookmark is gone or merged
   - topics (evolve) as an alternative to bookmarks
   - a test script in-repo (tests so far were ad-hoc shell; see "Testing" below)
   - Windows support (herdr supports it; this plugin is bash-only)

## Design decisions

- **hg share, not clones**: shares one store, so commits made in any share are
  instantly visible everywhere, and deleting a share loses only uncommitted work.
  Same model as `git worktree`.
- **Bookmarks stand in for branches** (`hg share -B` so bookmarks are shared).
  Named branches are permanent in hg, so they're a poor match for throwaway
  worktree branches.
- **No state file**: shares are discovered by scanning both layout locations
  and checking `.hg/sharedpath` → source. Changing layout never orphans anything.
- **Labels decide grouping**: `↳ x` / `repo ▸ x` labels are "generated". Only
  generated labels are rewritten, so a manual rename opts a workspace out.
- **Regroup only on create/open/source open/close/startup**, not on every focus,
  so dragging a share elsewhere isn't immediately undone.
- **Remote checks never block UI**: popups/CLI use cache only; network happens in
  event hooks (async from herdr's side) and backgrounded hg hooks.
- **Git is delegated, not reimplemented**: the plugin's keys call
  `herdr worktree …` in git repos so herdr keeps its real provenance/nesting.
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
XDG_CONFIG_HOME=$S/x HGRCPATH_USER=$S/hgrc HERDR_PLUGIN_CONFIG_DIR=$S/pc HGWT_BIN_DIR=$S/bin bin/hgwt-setup --yes
```

Clean up the test workspaces afterwards (`hgwt close-group` from the test repo).
`HGWT_FOCUS=0` keeps tests from stealing focus from your current pane.
