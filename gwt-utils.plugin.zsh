#!/usr/bin/env zsh
# gwt-utils — git worktree + tmux session helpers
# https://github.com/pranavraja/gwt-utils
#
# Public:  gwtnew, gwtcs, gwtdel
# Private: _gwt_* (implementation detail, may change without notice)

# --- Dependency probe (run at load) ------------------------------------------
() {
  local missing=()
  local cmd
  for cmd in git tmux fzf; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing} )) && \
    print -u2 "gwt-utils: missing dependencies: ${missing[*]}"
}

# --- Private helpers ---------------------------------------------------------

_gwt_require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 && return 0
  print -u2 "gwt-utils: not inside a git repository"
  return 1
}

# Prints the primary worktree's absolute path.
# First `worktree` line from `worktree list --porcelain` is always the primary,
# regardless of which linked worktree the command is invoked from.
_gwt_main_root() {
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0, 10); exit}'
}

_gwt_repo_name() {
  basename "$(_gwt_main_root)"
}

_gwt_session_name() {
  printf '%s/%s' "$(_gwt_repo_name)" "$1"
}

_gwt_worktree_path() {
  printf '%s/.worktrees/%s' "$(_gwt_main_root)" "$1"
}

# Returns 0 if branch exists as local, remote-tracking, or remote ref.
_gwt_branch_exists_anywhere() {
  local branch="$1"
  git show-ref --verify --quiet "refs/heads/$branch"          && return 0
  git show-ref --verify --quiet "refs/remotes/origin/$branch" && return 0
  # ls-remote as last resort — network call, only runs if earlier checks missed.
  local root="$(_gwt_main_root)"
  git -C "$root" ls-remote --exit-code --heads origin "$branch" \
    >/dev/null 2>&1 && return 0
  return 1
}

_gwt_switch_or_attach() {
  local session="$1"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "=$session"
  else
    tmux attach-session -t "=$session"
  fi
}

# Create tmux session iff it doesn't exist. The `=` prefix on -t forces an
# exact-match lookup — without it, `has-session -t foo` matches `foobar` too.
_gwt_ensure_session() {
  local session="$1" cwd="$2"
  tmux has-session -t "=$session" 2>/dev/null && return 0
  tmux new-session -d -s "$session" -c "$cwd"
}

# --- Public: gwtnew ----------------------------------------------------------

gwtnew() {
  _gwt_require_repo || return 1

  local branch=""
  vared -p "new branch name: " branch
  if [[ -z "$branch" || "$branch" == *[[:space:]]* ]]; then
    print -u2 "gwt-utils: branch name must be non-empty with no whitespace"
    return 1
  fi

  if _gwt_branch_exists_anywhere "$branch"; then
    print -u2 "gwt-utils: branch '$branch' already exists (local, remote, or tracking). Try gwtcs."
    return 1
  fi

  local wt="$(_gwt_worktree_path "$branch")"
  if [[ -e "$wt" ]]; then
    print -u2 "gwt-utils: worktree path already exists: $wt"
    return 1
  fi

  local base="main"
  vared -p "base branch: " base

  local root="$(_gwt_main_root)"
  git -C "$root" fetch origin --quiet 2>/dev/null || true

  local resolved=""
  if git -C "$root" rev-parse --verify --quiet "$base" >/dev/null; then
    resolved="$base"
  elif git -C "$root" rev-parse --verify --quiet "origin/$base" >/dev/null; then
    resolved="origin/$base"
  else
    print -u2 "gwt-utils: base '$base' not resolvable as local or origin/ ref"
    return 1
  fi

  git -C "$root" worktree add -b "$branch" "$wt" "$resolved" || return 1

  local session="$(_gwt_session_name "$branch")"
  _gwt_ensure_session "$session" "$wt"
  _gwt_switch_or_attach "$session"
}

# --- Public: gwtcs (create session from existing branch) ---------------------

gwtcs() {
  _gwt_require_repo || return 1

  local root="$(_gwt_main_root)"
  git -C "$root" fetch origin --quiet 2>/dev/null || true

  # Collect ref sets. `(f)` splits on newlines into an array.
  local -a locals remotes checked_out
  locals=(${(f)"$(git -C "$root" for-each-ref \
    --format='%(refname:short)' refs/heads/)"})
  remotes=(${(f)"$(git -C "$root" for-each-ref \
    --format='%(refname)' refs/remotes/origin/ \
    | grep -v '/HEAD$' \
    | sed 's|^refs/remotes/origin/||')"})
  checked_out=(${(f)"$(git -C "$root" worktree list --porcelain \
    | awk '/^branch /{sub("refs/heads/","",$2); print $2}')"})

  # Tag membership maps.
  local -A in_local in_remote excluded
  local b
  for b in $locals;      do in_local[$b]=1;  done
  for b in $remotes;     do in_remote[$b]=1; done
  for b in $checked_out; do excluded[$b]=1;  done

  # Build picker lines: union of locals + remotes, minus checked_out, deduped.
  local -a lines seen
  local tag
  for b in $locals $remotes; do
    (( ${seen[(Ie)$b]} )) && continue
    seen+=($b)
    [[ -n "${excluded[$b]}" ]] && continue
    if [[ -n "${in_local[$b]}" && -n "${in_remote[$b]}" ]]; then
      tag="[local,origin]"
    elif [[ -n "${in_local[$b]}" ]]; then
      tag="[local]"
    else
      tag="[origin]"
    fi
    lines+=("$(printf '%-40s %s' "$b" "$tag")")
  done

  if (( ${#lines} == 0 )); then
    print "gwt-utils: no branches without worktrees"
    return 0
  fi

  local picks=""
  picks="$(print -l -- $lines | fzf-tmux -p 80%,60% --multi \
    --prompt 'worktree> ' \
    --header 'TAB: toggle  ENTER: confirm')" || return 0
  [[ -z "$picks" ]] && return 0

  # Strip padding+tag; `awk '{print $1}'` gives the branch name.
  local -a picked
  picked=(${(f)"$(print -r -- "$picks" | awk '{print $1}')"})

  # Note: declare loop-local vars ONCE with explicit init. Using `local wt;`
  # inside the loop would trigger zsh's `typeset`-display quirk on subsequent
  # iterations (printing "wt=<prev value>" to stdout).
  local wt="" session=""
  local -a created=()
  for b in $picked; do
    if ! git -C "$root" show-ref --verify --quiet "refs/heads/$b"; then
      git -C "$root" branch --track "$b" "origin/$b" || continue
    fi
    wt="$(_gwt_worktree_path "$b")"
    git -C "$root" worktree add "$wt" "$b" || continue
    session="$(_gwt_session_name "$b")"
    _gwt_ensure_session "$session" "$wt"
    created+=("$session")
    print "created: $session"
  done

  if (( ${#created} == 1 )); then
    _gwt_switch_or_attach "${created[1]}"
  fi
}

# --- Public: gwtdel ----------------------------------------------------------

gwtdel() {
  _gwt_require_repo || return 1

  local root="$(_gwt_main_root)"
  local cwd_wt="$(git rev-parse --show-toplevel 2>/dev/null)"

  # Parse worktree list porcelain into lines of "<branch>\t<wt_path>".
  # Records are blank-line separated; skip the primary, skip cwd, skip
  # detached-HEAD entries (no branch).
  # NB: name this variable `wt_path`, NOT `path` — `path` is a zsh-tied array
  # variable that mirrors $PATH. Declaring `local path=""` and assigning to it
  # silently clobbers the environment's PATH. (Same applies to `cdpath`,
  # `fpath`, `manpath`, `module_path`.)
  local porcelain="$(git -C "$root" worktree list --porcelain)"
  local -a lines=()
  local wt_path="" branch="" line=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }" ;;
      "branch "*)   branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
      "")
        if [[ -n "$wt_path" && -n "$branch" && "$wt_path" != "$root" && "$wt_path" != "$cwd_wt" ]]; then
          lines+=("${branch}"$'\t'"${wt_path}")
        fi
        wt_path=""; branch=""
        ;;
    esac
  done <<< "$porcelain"
  # Final record (porcelain may omit trailing blank line).
  if [[ -n "$wt_path" && -n "$branch" && "$wt_path" != "$root" && "$wt_path" != "$cwd_wt" ]]; then
    lines+=("${branch}"$'\t'"${wt_path}")
  fi

  if (( ${#lines} == 0 )); then
    print "gwt-utils: no deletable worktrees"
    return 0
  fi

  # Present tab-separated lines; fzf's default delimiter handles them.
  local picks=""
  picks="$(print -l -- $lines | fzf-tmux -p 80%,60% --multi \
    --delimiter=$'\t' --with-nth=1 \
    --prompt 'delete> ' \
    --header 'TAB: multi-select  ENTER: confirm')" || return 0
  [[ -z "$picks" ]] && return 0

  local b="" wt_path="" ans=""
  while IFS=$'\t' read -r b wt_path; do
    [[ -z "$b" || -z "$wt_path" ]] && continue
    tmux kill-session -t "=$(_gwt_session_name "$b")" 2>/dev/null
    git -C "$root" worktree remove --force "$wt_path" || continue
    ans="n"
    vared -p "delete local branch '$b'? [y/N]: " ans
    if [[ "$ans" == [yY]* ]]; then
      git -C "$root" branch -D "$b"
    fi
  done <<< "$picks"

  git -C "$root" worktree prune
}
