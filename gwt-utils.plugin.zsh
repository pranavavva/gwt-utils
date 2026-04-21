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
  local root; root="$(_gwt_main_root)"
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
