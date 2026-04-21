# gwt-utils

Zsh functions that couple git worktrees with tmux sessions, packaged as an
[oh-my-zsh](https://ohmyz.sh) plugin.

## What it does

Adds three commands that extend OMZ's built-in `gwt*` git-worktree aliases:

| Command  | Purpose                                                                                                                                                                          |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gwtnew` | Prompt for a new branch name + base, create worktree at `.worktrees/<branch>`, spawn a tmux session named `<repo>/<branch>`, switch your tmux client into it.                    |
| `gwtcs`  | `fzf-tmux` multi-select picker over branches (local + `origin`) that don't yet have a worktree. Creates worktree + session for each pick. Auto-switches only when one is picked. |
| `gwtdel` | `fzf-tmux` multi-select picker over worktrees (excluding the primary and your current cwd). Kills the tmux session, removes the worktree, optionally deletes the branch.         |

## Dependencies

- zsh + oh-my-zsh
- git ≥ 2.5 (worktree subcommand)
- tmux
- fzf (ships `fzf-tmux` alongside `fzf`)

The plugin prints a one-line stderr warning at shell startup if any are
missing, and defines the functions anyway so a partial environment doesn't
break your shell.

## Install

Clone into your oh-my-zsh custom plugins directory:

```sh
git clone https://github.com/pranavavva/gwt-utils \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/gwt-utils
```

Add `gwt-utils` to the `plugins=(...)` array in `~/.zshrc`:

```zsh
plugins=(git ... gwt-utils)
```

Restart your shell or `source ~/.zshrc`.

## One-time setup: global gitignore

Worktrees live under `.worktrees/` inside each repo. Rather than add this to
every repo's `.gitignore`, put it in your global ignore file:

```sh
echo '.worktrees/' >> ~/.config/git/ignore
```

Git reads `~/.config/git/ignore` by default; if yours is configured elsewhere
(check `git config --get core.excludesFile`), adjust accordingly.

## Usage

### Start a new feature

```sh
cd ~/src/myrepo
gwtnew
# new branch name: feat/cool-thing          <enter>
# base branch: main                         <enter>   (prefilled, editable)
# → worktree at ~/src/myrepo/.worktrees/feat/cool-thing
# → tmux session 'myrepo/feat/cool-thing'
# → your tmux client switches into it
```

### Resume work on existing branches (e.g. after a reboot)

```sh
cd ~/src/myrepo
gwtcs
# fzf picker opens. TAB to toggle, ENTER to confirm multi-selection.
# Branches are tagged [local], [origin], or [local,origin].
# For each pick: creates worktree + tmux session.
#   - If the branch was remote-only, a local tracking branch is created first.
#   - Single pick → auto-switches into that session.
#   - Multiple picks → all sessions created detached, no switch.
```

### Clean up merged branches

```sh
cd ~/src/myrepo
gwtdel
# fzf picker opens. All worktrees listed EXCEPT:
#   - the primary worktree (main repo)
#   - the worktree containing your current cwd
#   - detached-HEAD worktrees (manage those with raw `git worktree remove`)
# TAB-select one or more, ENTER to confirm.
# For each: kills tmux session, removes worktree (force).
# Then prompts "delete local branch 'X'? [y/N]" — defaults to N.
```

## Conventions

- **Worktree location** — always `<main_repo>/.worktrees/<branch>`, regardless
  of which worktree you invoke the command from. Branch names with slashes
  (e.g. `feat/auth`) produce nested directories (`.worktrees/feat/auth`).
- **tmux session name** — `<repo>/<branch>`. Slashes in branch names are
  preserved. tmux silently replaces `:` and `.` with `_` in session names
  (they're reserved target-spec separators); the plugin accepts this rather
  than pre-sanitising.
- **Auto-switch behaviour** —
  - `gwtnew` always switches.
  - `gwtcs` switches only when exactly one branch was picked.
  - `gwtdel` never switches. If you were inside a killed session, tmux moves
    you to another existing session automatically.

## Gotchas

- `gwtdel` uses `git worktree remove --force` — **uncommitted changes in a
  selected worktree are discarded**. The fzf confirmation is the gate.
- `gwtnew` rejects branch names that exist anywhere (local, remote-tracking,
  or remote). Use `gwtcs` for existing branches.
- Only the `origin` remote is consulted. Multi-remote setups aren't supported
  in v1.
- Detached-HEAD worktrees are hidden from the `gwtdel` picker to keep the UI
  clean. Remove them with plain `git worktree remove`.

## Development

```sh
git clone https://github.com/pranavavva/gwt-utils ~/src/gwt-utils
cd ~/src/gwt-utils
# iterate on gwt-utils.plugin.zsh, then:
source ~/src/gwt-utils/gwt-utils.plugin.zsh   # add to .zshrc for reload-free dev
```

See [`DESIGN.md`](./DESIGN.md) for the design rationale and
[`PLAN.md`](./PLAN.md) for the implementation plan.

## License

MIT — see [`LICENSE`](./LICENSE).
