# gwt-utils Implementation Plan

**Goal:** Ship an oh-my-zsh plugin that wires `gwtnew` / `gwtcs` / `gwtdel` into
existing git-worktree + tmux workflows, installable via standard OMZ
external-plugin pattern.

**Architecture:** Single-file zsh plugin `gwt-utils.plugin.zsh` with a
dependency probe, 8 private `_gwt_*` helpers, and 3 public functions. No
automated tests — smoke-tested manually in a throwaway repo per task.

**Tech Stack:** zsh (functions, `vared`), git (worktree subcommand), tmux
(sessions, switch-client), fzf/fzf-tmux (multi-select picker).

**Non-TDD note:** Per design, no bats or other automated tests. Each task ends
with a manual smoke test in a throwaway repo and a commit.

---

## File map

| File | Responsibility |
| ---- | -------------- |
| `gwt-utils.plugin.zsh` | Plugin entrypoint: dep probe, all helpers, 3 public functions |
| `README.md` | Install instructions, usage, gotchas, gitignore step |
| `LICENSE` | MIT |
| `DESIGN.md` | (already exists) |
| `.gitignore` | (already exists, no change) |

Single file for the plugin is appropriate — everything is tightly coupled, ~150
lines total, and a single-file plugin matches OMZ convention.

---

## Throwaway test repo setup

Tasks 3-5 need a real repo for smoke-testing. One-time setup:

```bash
mkdir -p /tmp/gwt-test-origin /tmp/gwt-test
cd /tmp/gwt-test-origin && git init --bare
cd /tmp/gwt-test && git init && git remote add origin /tmp/gwt-test-origin
echo hi > README && git add . && git commit -m init
git branch -M main && git push -u origin main
# seed a few branches for gwtcs testing later:
git branch feat/a && git push -u origin feat/a
git branch feat/b && git push -u origin feat/b
git push origin --delete feat/a  # keep feat/a local-only for variety
```

Invoke each public function from inside `/tmp/gwt-test/`.

---

## Task 1: Scaffold (LICENSE, README stub), stage DESIGN.md

**Files:**
- Create: `LICENSE`
- Create: `README.md` (stub)

- [ ] **Step 1.1:** Write `LICENSE` (standard MIT, user = Pranav Raja, year = 2026).

- [ ] **Step 1.2:** Write `README.md` stub with just the title and a `# WIP` marker. Full README written in Task 6.

- [ ] **Step 1.3:** Commit scaffold.

```bash
git add DESIGN.md PLAN.md LICENSE README.md
git commit -m "docs: initial design, plan, license, readme scaffold"
```

---

## Task 2: Plugin entrypoint — dep probe + all private helpers

**Files:**
- Create: `gwt-utils.plugin.zsh`

All 8 helpers in one task because they're small, interdependent, and have no
tests — separating them would add commit noise without value.

- [ ] **Step 2.1:** Create `gwt-utils.plugin.zsh` with header comment, dep probe, and helpers.

```zsh
#!/usr/bin/env zsh
# gwt-utils — git worktree + tmux session helpers
# https://github.com/<user>/gwt-utils

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
  # ls-remote as last resort — network call, only runs if earlier checks missed
  local root; root="$(_gwt_main_root)"
  git -C "$root" ls-remote --exit-code --heads origin "$branch" \
    >/dev/null 2>&1 && return 0
  return 1
}

_gwt_switch_or_attach() {
  local session="$1"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

_gwt_ensure_session() {
  local session="$1" cwd="$2"
  tmux has-session -t "=$session" 2>/dev/null && return 0
  tmux new-session -d -s "$session" -c "$cwd"
}
```

Note on `tmux has-session -t "=$session"`: the `=` prefix forces an exact-match
against the session name instead of tmux's default prefix match. Without it,
`tmux has-session -t foo` would match session `foobar` too — a real footgun for
repos with branch-name prefix overlap.

- [ ] **Step 2.2:** Smoke test — source and call helpers from inside `/tmp/gwt-test/`.

```bash
cd /tmp/gwt-test
source ~/src/gwt-utils/gwt-utils.plugin.zsh
# expect: no warnings (git/tmux/fzf all installed)

_gwt_require_repo && echo ok
# expect: ok

_gwt_main_root
# expect: /tmp/gwt-test (or /private/tmp/gwt-test on macOS)

_gwt_repo_name
# expect: gwt-test

_gwt_session_name "feature/foo"
# expect: gwt-test/feature/foo

_gwt_worktree_path "feature/foo"
# expect: <main_root>/.worktrees/feature/foo

_gwt_branch_exists_anywhere main && echo exists
# expect: exists

_gwt_branch_exists_anywhere nonexistent-branch-xyz || echo nope
# expect: nope
```

Then verify the `=` prefix behavior:

```bash
tmux new-session -d -s foobar -c /tmp 2>/dev/null
tmux has-session -t "=foo" 2>/dev/null && echo "BUG: prefix-matched" || echo ok
# expect: ok
tmux kill-session -t foobar
```

- [ ] **Step 2.3:** Commit.

```bash
git add gwt-utils.plugin.zsh
git commit -m "feat: plugin entrypoint with dep probe and private helpers"
```

---

## Task 3: `gwtnew`

**Files:**
- Modify: `gwt-utils.plugin.zsh` (append)

- [ ] **Step 3.1:** Append `gwtnew` to the plugin file.

```zsh
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

  local wt; wt="$(_gwt_worktree_path "$branch")"
  if [[ -e "$wt" ]]; then
    print -u2 "gwt-utils: worktree path already exists: $wt"
    return 1
  fi

  local base="main"
  vared -p "base branch: " base

  local root; root="$(_gwt_main_root)"
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

  local session; session="$(_gwt_session_name "$branch")"
  _gwt_ensure_session "$session" "$wt"
  _gwt_switch_or_attach "$session"
}
```

- [ ] **Step 3.2:** Smoke test.

```bash
cd /tmp/gwt-test
source ~/src/gwt-utils/gwt-utils.plugin.zsh

# Happy path:
gwtnew
# type: my-feature <enter>
# accept base main <enter>
# expect: worktree at /tmp/gwt-test/.worktrees/my-feature
#         tmux session gwt-test/my-feature exists and you're switched into it

# Verify from a fresh shell:
tmux ls | grep gwt-test/my-feature
ls /tmp/gwt-test/.worktrees/my-feature
cd /tmp/gwt-test && git worktree list

# Failure: duplicate branch
gwtnew
# type: my-feature
# expect: error "branch 'my-feature' already exists"

# Failure: bad base
gwtnew
# type: other-feat
# base: nonexistent
# expect: error "base 'nonexistent' not resolvable"

# Cleanup:
tmux kill-session -t gwt-test/my-feature 2>/dev/null
cd /tmp/gwt-test && git worktree remove --force .worktrees/my-feature
git branch -D my-feature
```

- [ ] **Step 3.3:** Commit.

```bash
git add gwt-utils.plugin.zsh
git commit -m "feat: gwtnew — new branch + worktree + tmux session"
```

---

## Task 4: `gwtcs`

**Files:**
- Modify: `gwt-utils.plugin.zsh` (append)

- [ ] **Step 4.1:** Append `gwtcs`.

```zsh
# --- Public: gwtcs (create session from existing branch) ---------------------

gwtcs() {
  _gwt_require_repo || return 1

  local root; root="$(_gwt_main_root)"
  git -C "$root" fetch origin --quiet 2>/dev/null || true

  # Collect sets.
  local -a locals remotes checked_out
  locals=(${(f)"$(git -C "$root" for-each-ref \
    --format='%(refname:short)' refs/heads/)"})
  remotes=(${(f)"$(git -C "$root" for-each-ref \
    --format='%(refname:short)' refs/remotes/origin/ \
    | grep -v '/HEAD$' | sed 's|^origin/||')"})
  checked_out=(${(f)"$(git -C "$root" worktree list --porcelain \
    | awk '/^branch /{sub("refs/heads/","",$2); print $2}')"})

  # Build associative arrays for source tags.
  typeset -A in_local in_remote excluded
  local b
  for b in $locals;      do in_local[$b]=1;  done
  for b in $remotes;     do in_remote[$b]=1; done
  for b in $checked_out; do excluded[$b]=1;  done

  # Candidates = (locals ∪ remotes) \ checked_out, with tag column.
  local -a lines
  local tag
  for b in ${(ou)locals} ${(ou)remotes}; do
    [[ -n "${excluded[$b]}" ]] && continue
    # dedupe: only add each branch once
    [[ -n "${_gwt_seen[$b]}" ]] && continue
    typeset -A _gwt_seen=(${_gwt_seen} $b 1) 2>/dev/null
    if [[ -n "${in_local[$b]}" && -n "${in_remote[$b]}" ]]; then
      tag="[local,origin]"
    elif [[ -n "${in_local[$b]}" ]]; then
      tag="[local]"
    else
      tag="[origin]"
    fi
    lines+=("$(printf '%-40s %s' "$b" "$tag")")
  done
  unset _gwt_seen

  if (( ${#lines} == 0 )); then
    print "gwt-utils: no branches without worktrees"
    return 0
  fi

  local picks
  picks="$(print -l $lines | fzf-tmux -p 80%,60% --multi \
    --prompt 'worktree> ' \
    --header 'TAB: toggle  ENTER: confirm')" || return 0
  [[ -z "$picks" ]] && return 0

  local -a picked
  picked=(${(f)"$(print -r -- "$picks" | awk '{print $1}')"})

  local created=()
  for b in $picked; do
    if ! git -C "$root" show-ref --verify --quiet "refs/heads/$b"; then
      git -C "$root" branch --track "$b" "origin/$b" || continue
    fi
    local wt; wt="$(_gwt_worktree_path "$b")"
    git -C "$root" worktree add "$wt" "$b" || continue
    local session; session="$(_gwt_session_name "$b")"
    _gwt_ensure_session "$session" "$wt"
    created+=("$session")
    print "created: $session"
  done

  if (( ${#created} == 1 )); then
    _gwt_switch_or_attach "${created[1]}"
  fi
}
```

Note on the dedupe: the simpler idiom is an associative array `seen`, and I use
`${(ou)...}` on the combined list to let zsh dedupe — but that alone doesn't
merge tag info. The `in_local`/`in_remote` maps drive the tag column; the
`(ou)` flag gives us unique entries in stable order.

(Actually, the `_gwt_seen` shenanigan above is redundant given `(ou)`. Simplify
at implementation time — remove the `_gwt_seen` block.)

- [ ] **Step 4.2:** Smoke test.

Setup: in `/tmp/gwt-test`, ensure `feat/a` is local-only and `feat/b` is
remote-only (recreate if needed):

```bash
cd /tmp/gwt-test
git branch feat/a 2>/dev/null
git push origin feat/b --force-with-lease 2>/dev/null || git branch feat/b && git push -u origin feat/b
git branch -D feat/b 2>/dev/null  # make feat/b remote-only
git fetch origin --prune
```

Then:

```bash
source ~/src/gwt-utils/gwt-utils.plugin.zsh
gwtcs
# picker should show:
#   feat/a    [local]
#   feat/b    [origin]
# Pick just feat/b with ENTER.
# expect: local tracking branch created, worktree at .worktrees/feat/b,
#         tmux session gwt-test/feat/b, auto-switched.

# Multi-select:
# Cleanup first:
tmux kill-session -t gwt-test/feat/b 2>/dev/null
cd /tmp/gwt-test && git worktree remove --force .worktrees/feat/b && git branch -D feat/b

gwtcs
# TAB to select feat/a AND feat/b, then ENTER.
# expect: both worktrees created, both sessions created, NO auto-switch.
tmux ls | grep gwt-test
```

- [ ] **Step 4.3:** Commit.

```bash
git add gwt-utils.plugin.zsh
git commit -m "feat: gwtcs — fzf-tmux picker for existing branches"
```

---

## Task 5: `gwtdel`

**Files:**
- Modify: `gwt-utils.plugin.zsh` (append)

- [ ] **Step 5.1:** Append `gwtdel`.

```zsh
# --- Public: gwtdel ----------------------------------------------------------

gwtdel() {
  _gwt_require_repo || return 1

  local root; root="$(_gwt_main_root)"
  local cwd_wt; cwd_wt="$(git rev-parse --show-toplevel 2>/dev/null)"

  # Parse worktree list into (path, branch) tuples, skipping primary/cwd/detached.
  local -a lines
  local path="" branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }";;
      branch\ *)   branch="${line#branch }"; branch="${branch#refs/heads/}";;
      "")
        if [[ -n "$path" && -n "$branch" && "$path" != "$root" && "$path" != "$cwd_wt" ]]; then
          lines+=("$(printf '%-40s %s' "$branch" "$path")")
        fi
        path=""; branch=""
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain)
  # Handle final record (no trailing blank line):
  if [[ -n "$path" && -n "$branch" && "$path" != "$root" && "$path" != "$cwd_wt" ]]; then
    lines+=("$(printf '%-40s %s' "$branch" "$path")")
  fi

  if (( ${#lines} == 0 )); then
    print "gwt-utils: no deletable worktrees"
    return 0
  fi

  local picks
  picks="$(print -l $lines | fzf-tmux -p 80%,60% --multi \
    --prompt 'delete> ' \
    --header 'TAB: multi-select  ENTER: confirm')" || return 0
  [[ -z "$picks" ]] && return 0

  # Parse each picked line back into (branch, path).
  local line b p ans
  while IFS= read -r line; do
    b="${line%%[[:space:]]*}"
    p="${line##*[[:space:]]}"
    tmux kill-session -t "=$(_gwt_session_name "$b")" 2>/dev/null
    git -C "$root" worktree remove --force "$p" || continue
    ans="n"
    vared -p "delete local branch '$b'? [y/N]: " ans
    if [[ "$ans" == [yY]* ]]; then
      git -C "$root" branch -D "$b"
    fi
  done <<< "$picks"

  git -C "$root" worktree prune
}
```

- [ ] **Step 5.2:** Smoke test.

```bash
# Setup: create 3 worktrees
cd /tmp/gwt-test
source ~/src/gwt-utils/gwt-utils.plugin.zsh

# Create them quickly (bypass gwtnew so the test is fast):
for b in del-a del-b del-c; do
  git worktree add -b "$b" ".worktrees/$b" main
  tmux new-session -d -s "gwt-test/$b" -c ".worktrees/$b"
done

gwtdel
# expect picker shows del-a, del-b, del-c — NOT main, NOT your cwd.
# TAB-select del-a + del-b, ENTER.
# for each: answer N to the branch-delete prompt, then Y for one to verify delete.
# expect: two worktrees removed, two sessions killed, del-c still present.

# Verify:
git worktree list
tmux ls | grep gwt-test
git branch
```

Verify safety rail — try running gwtdel from INSIDE a worktree:

```bash
cd /tmp/gwt-test/.worktrees/del-c
gwtdel
# expect: picker does NOT show del-c (cwd filter). Main also absent.
```

Cleanup:

```bash
cd /tmp/gwt-test
for b in del-a del-b del-c; do
  tmux kill-session -t "=gwt-test/$b" 2>/dev/null
  git worktree remove --force ".worktrees/$b" 2>/dev/null
  git branch -D "$b" 2>/dev/null
done
```

- [ ] **Step 5.3:** Commit.

```bash
git add gwt-utils.plugin.zsh
git commit -m "feat: gwtdel — fzf multi-select worktree cleanup"
```

---

## Task 6: README with full install + usage + gotchas

**Files:**
- Modify: `README.md`

- [ ] **Step 6.1:** Replace stub with full README.

````markdown
# gwt-utils

Zsh functions that couple git worktrees with tmux sessions, built as an
[oh-my-zsh](https://ohmyz.sh) plugin.

## What it does

Adds three commands that extend OMZ's built-in `gwt*` git-worktree aliases:

| Command | Purpose |
| ------- | ------- |
| `gwtnew` | Prompt for a new branch name + base, create worktree in `.worktrees/<branch>`, spawn a tmux session named `<repo>/<branch>`, switch your tmux client to it. |
| `gwtcs`  | `fzf-tmux` multi-select picker over branches (local + remote) that don't yet have a worktree. Creates worktree + session for each pick. Auto-switches only when one is picked. |
| `gwtdel` | `fzf-tmux` multi-select picker over worktrees (excluding primary + your current cwd). Kills the tmux session, removes the worktree, optionally deletes the branch. |

## Dependencies

- zsh + oh-my-zsh
- git ≥ 2.5 (worktree subcommand)
- tmux
- fzf (supplies `fzf-tmux`)

## Install

```sh
git clone https://github.com/<user>/gwt-utils \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/gwt-utils
```

Add `gwt-utils` to the `plugins=(...)` array in `~/.zshrc`:

```zsh
plugins=(git ... gwt-utils)
```

Restart your shell or `source ~/.zshrc`.

## One-time setup: global gitignore

Worktrees live under `.worktrees/` inside each repo. To stop every repo from
needing this in its own `.gitignore`, add it to your global ignore file:

```sh
echo '.worktrees/' >> ~/.config/git/ignore
```

(Git reads `~/.config/git/ignore` by default. If you use a different location,
adjust accordingly.)

## Usage

### Start a new feature

```sh
cd ~/src/myrepo
gwtnew
# new branch name: feat/cool-thing
# base branch: main
# → worktree at ~/src/myrepo/.worktrees/feat/cool-thing
# → tmux session 'myrepo/feat/cool-thing'
# → your tmux client switches into it
```

### Resume work on existing branches after a reboot

```sh
cd ~/src/myrepo
gwtcs
# fzf multi-select opens. TAB to toggle, ENTER to confirm.
# Picks any branch without a worktree — local or origin-only.
# Creates a worktree + tmux session for each.
```

### Clean up merged branches

```sh
cd ~/src/myrepo
gwtdel
# fzf multi-select opens with all worktrees except the primary and your cwd.
# Kills tmux session, removes worktree. Prompts y/N for branch deletion (default N).
```

## Conventions

- **Worktree location**: always `<main_repo>/.worktrees/<branch>`, regardless
  of which worktree you run the command from.
- **tmux session name**: `<repo>/<branch>`. Slashes in branch names (e.g.
  `feat/auth`) are preserved. `:` and `.` are silently replaced with `_` by
  tmux itself.
- **Auto-switch**: `gwtnew` always switches. `gwtcs` switches only when one
  branch is picked. `gwtdel` never switches.

## Gotchas

- `gwtdel` uses `git worktree remove --force` — uncommitted changes in a
  selected worktree are discarded. The fzf confirmation is the gate.
- `gwtnew` rejects branch names that exist anywhere (local, remote-tracking,
  or remote). Use `gwtcs` for existing branches.
- Detached-HEAD worktrees are hidden from `gwtdel` to keep the UI simple.
  Remove them with plain `git worktree remove`.

## License

MIT
````

- [ ] **Step 6.2:** Commit.

```bash
git add README.md
git commit -m "docs: full readme with install, usage, and gotchas"
```

---

## Self-review checklist (run after writing the plan)

- **Spec coverage:**
  - [x] `gwtnew` flow matches spec section "gwtnew" → Task 3.
  - [x] `gwtcs` flow with multi-select + source tagging → Task 4.
  - [x] `gwtdel` with primary+cwd filter, y/N default N → Task 5.
  - [x] All 8 private helpers → Task 2.
  - [x] Dep probe → Task 2.
  - [x] OMZ plugin distribution (filename, install) → Task 1 + 6.
  - [x] Global gitignore documented (not automated) → Task 6 README.
  - [x] Out-of-scope items correctly omitted (no tests, no gh, no env vars).

- **Placeholder scan:** One intentional `<user>` in README and install snippet
  — user will replace with their GitHub username once the repo is pushed. Not
  a plan failure; noted.

- **Type/name consistency:** `_gwt_ensure_session`, `_gwt_session_name`,
  `_gwt_worktree_path`, `_gwt_main_root` — names stable across tasks. Public
  functions always `gwtnew`/`gwtcs`/`gwtdel`, never alt forms.

- **Known simplification flagged:** Task 4.1 has a `_gwt_seen` dedupe block
  marked for removal during implementation (`${(ou)...}` already dedupes).
  Will simplify when writing the actual file.
