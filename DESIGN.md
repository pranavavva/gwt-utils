# gwt-utils — Design

An oh-my-zsh plugin providing three functions that layer on top of OMZ's
built-in `gwt*` git-worktree aliases to couple each worktree with an optional
tmux session. Distributed as a public GitHub repo, installed via the standard
OMZ external-plugin pattern.

## Motivation

Each branch I actively work on should be able to live in its own worktree
(sibling dir under the main repo's `.worktrees/`) and have a matching tmux
session I can jump into via `opt-s`. Creating, resuming, and disposing of these
pairs should be one-command operations.

## Scope

Three public functions and one documented manual gitignore step.

| Function | Input | Effect |
| -------- | ----- | ------ |
| `gwtnew` | interactive prompts (branch name, base branch) | new branch + worktree + tmux session, auto-switch client |
| `gwtcs`  | `fzf-tmux` multi-select over existing branches without worktrees | worktree + tmux session per pick; auto-switch only if 1 picked |
| `gwtdel` | `fzf-tmux` multi-select over existing worktrees (minus primary and cwd) | kill session, remove worktree, optionally delete branch |

## Non-goals

- No automatic editing of `~/.config/git/ignore` — documented as a one-time
  manual step in README.
- No config file or `GWT_*` env vars — behavior is hardcoded.
- No `gh`/PR integration (candidate for a future `gwtpr`).
- No automated tests (bats or otherwise). Manual verification only.
- No shell-completion files (`_gwtnew` etc.) in v1.
- `opt-s` tmux session picker is the user's tmux.conf binding, not part of this plugin.

## Distribution

Public GitHub repo, installed via the OMZ external-plugin convention:

```sh
git clone https://github.com/<user>/gwt-utils \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/gwt-utils
```

Then in `~/.zshrc`:

```zsh
plugins=(... gwt-utils)
```

OMZ auto-sources `$ZSH_CUSTOM/plugins/gwt-utils/gwt-utils.plugin.zsh` on shell
start. The plugin directory is auto-added to `$fpath`, which positions the repo
to add completion files later without changing install instructions.

### Local dev loop

During development in `~/src/gwt-utils/` (the author's working copy), add to
`~/.zshrc`:

```zsh
source ~/src/gwt-utils/gwt-utils.plugin.zsh
```

and reload. No need to add to `plugins=(...)` during dev — the plain `source`
makes iteration fast. Once satisfied, `git push` and either clone from
GitHub into `$ZSH_CUSTOM/plugins/gwt-utils` or symlink the working copy:

```sh
ln -s ~/src/gwt-utils ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/gwt-utils
```

## Dependency check on load

The plugin file's first action is a soft dependency probe — if any of `git`,
`tmux`, or `fzf` are missing, print a single stderr warning naming what's
absent. Functions are still defined (they'll fail at call time with their own
messages), so a partial environment doesn't break shell startup.

```zsh
() {
  local missing=()
  local cmd
  for cmd in git tmux fzf; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing} )) && \
    print -u2 "gwt-utils: missing dependencies: ${missing[*]}"
}
```

(`fzf-tmux` ships with fzf itself — checking `fzf` covers it.)

## File layout

```
~/src/gwt-utils/
├── gwt-utils.plugin.zsh   # main file, auto-sourced by OMZ
├── README.md              # install + usage + one-time gitignore step
├── LICENSE                # MIT
├── DESIGN.md              # this file
└── .gitignore
```

## Naming conventions

### tmux session name

Format: `<repo>/<branch>` where `<repo>` is the main worktree's directory
basename.

- `/` is valid in tmux session names → branches like `feature/auth` in repo
  `gwt-utils` produce session `gwt-utils/feature/auth`.
- tmux *silently rewrites* `:` and `.` to `_` in session names. Accepted as-is;
  we don't pre-sanitize.
- In `tmux ls`, the first path segment is always the repo name. Unambiguous.

### Worktree path

Always `<main_worktree_root>/.worktrees/<branch>`. Branch name used verbatim, so
`feature/auth` → `.worktrees/feature/auth` (nested dir, fine).

## Helper functions (private)

All prefixed `_gwt_` so they don't pollute the interactive namespace.

| Helper | Purpose |
| ------ | ------- |
| `_gwt_require_repo` | `git rev-parse --is-inside-work-tree` check; prints error + returns 1 if not in a repo |
| `_gwt_main_root` | Resolves main worktree root. Parses first `worktree` line from `git worktree list --porcelain` — that entry is always the primary, even when called from inside a linked worktree. More robust than `--git-common-dir` for bare repos and unusual setups |
| `_gwt_repo_name` | `basename "$(_gwt_main_root)"` |
| `_gwt_session_name <branch>` | `"$(_gwt_repo_name)/<branch>"` |
| `_gwt_worktree_path <branch>` | `"$(_gwt_main_root)/.worktrees/<branch>"` |
| `_gwt_branch_exists_anywhere <name>` | Returns 0 if branch exists as local ref, remote-tracking ref, or on any configured remote (via `git ls-remote`). Used by `gwtnew` to reject duplicates |
| `_gwt_switch_or_attach <session>` | If `$TMUX` set → `tmux switch-client -t`, else `tmux attach-session -t` |
| `_gwt_ensure_session <session> <cwd>` | `tmux has-session -t <session> 2>/dev/null` → if absent, `tmux new-session -d -s <session> -c <cwd>` |

## Public function behavior

### gwtnew

```
1. _gwt_require_repo || return 1
2. local branch=""
   vared -p "new branch name: " branch
   validate: non-empty, no whitespace → else fail
3. _gwt_branch_exists_anywhere "$branch" && fail
   (also check: no existing worktree at _gwt_worktree_path)
4. local base="main"
   vared -p "base branch: " base
5. git -C "$(_gwt_main_root)" fetch origin --quiet || true
   # non-fatal: local-only repos are valid
6. git -C "$(_gwt_main_root)" rev-parse --verify "$base" >/dev/null
   || git -C "$(_gwt_main_root)" rev-parse --verify "origin/$base" >/dev/null
   || fail "base '$base' not resolvable"
   # prefer local ref if both exist, else origin/<base>
7. local wt="$(_gwt_worktree_path "$branch")"
   git -C "$(_gwt_main_root)" worktree add -b "$branch" "$wt" "<resolved_base>"
8. local session="$(_gwt_session_name "$branch")"
   _gwt_ensure_session "$session" "$wt"
9. _gwt_switch_or_attach "$session"
```

Failure modes:
- Not a git repo → exit 1.
- Empty / whitespace branch name → exit 1, no side effects.
- Branch already exists (local, remote-tracking, or remote) → exit 1, no side effects. Message suggests `gwtcs`.
- Worktree path already exists on disk → exit 1.
- Base unresolvable → exit 1, no worktree or session created.
- `worktree add` fails → no session created (check exit code before step 8).

### gwtcs

```
1. _gwt_require_repo || return 1
2. git -C "$(_gwt_main_root)" fetch origin --quiet || true
3. Build candidate list:
     locals       = git for-each-ref --format='%(refname:short)' refs/heads/
     remotes      = git for-each-ref --format='%(refname:short)' refs/remotes/origin/
                     | grep -v '/HEAD$' | sed 's|^origin/||'
     checked_out  = git worktree list --porcelain
                     | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
     candidates   = sort -u (locals ∪ remotes) \ checked_out
   Display format, column-aligned: "<branch>  [local]" | "[origin]" | "[local,origin]"
   (tag derived by set membership; stripped via awk before handing to git)
4. If candidates empty → echo "no branches without worktrees" && return 0
5. echo "$candidates" | fzf-tmux -p 80%,60% --multi \
       --prompt "worktree> " \
       --header "TAB: toggle  ENTER: confirm"
6. For each picked branch (after stripping display tag):
     a. if ! git show-ref --verify --quiet "refs/heads/$branch":
          git branch --track "$branch" "origin/$branch"
     b. git -C "$main_root" worktree add "$(_gwt_worktree_path "$branch")" "$branch"
     c. _gwt_ensure_session "$(_gwt_session_name "$branch")" "$(_gwt_worktree_path "$branch")"
     d. echo "created: $(_gwt_session_name "$branch")"
7. If exactly 1 picked → _gwt_switch_or_attach "$session"
   Else → print all session names; no switch.
```

### gwtdel

```
1. _gwt_require_repo || return 1
2. local main_root="$(_gwt_main_root)"
   local cwd_wt="$(git rev-parse --show-toplevel)"
3. Build candidate list from `git worktree list --porcelain`:
     skip entries where path == main_root         (primary)
     skip entries where path == cwd_wt            (can't remove what you're in)
     skip entries with no branch (detached HEAD worktrees) — keep it simple
     format: "<branch>\t<path>"
4. If empty → echo "no deletable worktrees" && return 0
5. echo "$candidates" | fzf-tmux -p 80%,60% --multi \
       --prompt "delete> " \
       --header "TAB: multi-select  ENTER: confirm"
6. For each selected (branch, path):
     a. tmux kill-session -t "$(_gwt_session_name "$branch")" 2>/dev/null
     b. git -C "$main_root" worktree remove --force "$path"
     c. local ans="n"
        vared -p "delete local branch '$branch'? [y/N]: " ans
        [[ "$ans" == [yY]* ]] && git -C "$main_root" branch -D "$branch"
7. git -C "$main_root" worktree prune
```

Notes:
- `--force` on `worktree remove` discards uncommitted changes. The fzf
  confirmation is the gate; we trust the user. Documented in README.
- Kill-session before remove-worktree: avoids tmux holding a pane with cwd
  inside the doomed directory.
- After deletion, if you were switched to a killed session, tmux auto-moves
  you to another session (no explicit handling needed).

## Global gitignore

Append `.worktrees/` to `~/.config/git/ignore`. Documented in README as a
one-time manual step. The plugin will never modify files outside its own
directory.

```sh
echo '.worktrees/' >> ~/.config/git/ignore
```

## Open questions

None remaining. All design decisions locked in dialogue with user.

## Out of scope — candidates for v2

- `gwtpr <number>` — create worktree from `gh pr checkout`.
- Config file support (tmux session layout, default base branch per repo).
- `gwtdel --prune-merged` — auto-pick branches already merged into main.
- Shell completions: `_gwtnew`, `_gwtcs`, `_gwtdel` zstyle completers.
  Plugin dir is already on `$fpath` so adding these later is non-breaking.
- bats test suite.
