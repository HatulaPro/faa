# faa

## The problem

You keep **one** main repo open — dev server running, editor attached — and you
use it to run and verify work that your agents produce. Each agent works in its own
**git worktree** on its own feature branch, so several can run at once without
stepping on each other.

The trouble starts the moment you want to _try_ an agent's work. To run it in your
main repo you check out its branch — and git refuses: a branch can't be checked out
in two worktrees at once. So you detach, or juggle copies. Then the loop tightens:
you spot a fix and make it on main, but you can't commit it onto the agent's branch.
You want to pull the agent's latest while keeping your own half-finished edit on top, but the agent made more
changes and now the two have diverged and you're resolving merge conflicts —
and this is happening across two or three agents at once, so you're also switching
main between branches, losing track of which stash was for which feature.

Managing all of this is _possible_ with git — stashes, pulling, merging, checking out from a branch. It's just constant friction around a simple intent:
**hand work back and forth between a worktree and main.** You may have many branches, but for any given branch, the work is linear. Our tools should embrace that.

`faa` is a single bash script that simplifies this dance.

### Is it good for me?

I made it specifically optimized for my workflow with OpenCode and weak local agents. It is likely not a good fit for most people working with agents.

1. I do not trust the model to decide what to commit. I don't let it touch git at all. I made this under the assumption that all git handling is managed manually. If your agents are smart enough, maybe you can just let them do their thing.
2. The task's success is not easily testable. The model can fail to implement simple features or bug fixes. Even when it is as simple as "make the button bigger", I want to visually run the program and make sure it behaves as I want it to behave.
3. Running the dev server is costly - long install times, limited available ports, slow start ups. If you prefer to only run one dev server, this might be for you.
4. If you're developing on one branch at the time, `faa` will only make things more complicated.

## The model

For a feature branch (say `add-button`), main can't sit on `add-button` while the
worktree holds it. So main works on a per-feature **mirror** branch `faa-add-button`. Each side only ever moves its _own_ branch and _reads_ the other's, so the "checked out twice" / "can't force-update" errors are impossible,
and every sync is a fast-forward (faa never has to merge committed history).

```
   agent worktree                     main repo
   ──────────────                     ─────────
   branch:  add-button   ── faa ──▶   branch:  faa-add-button   (verify / tweak)
   (agent edits here)    ◀── faa ──   (your fixes here)
            │                              │
            └──────── shared .git  ────────┘
```

## Commands

| Command                    | Where      | What it does                                                                                                                                                                                                                               |
| -------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `faa`                      | worktree   | Save your work (commit). If main pushed something, it pulls that first — then run `faa` again to save your edits on top.                                                                                                                   |
| `faa`                      | main       | Check out & pull the **newest** finished worktree (switching to it if needed). If it's the feature you're already on, your uncommitted edits stay on top. Refuses to switch if that would abandon uncommitted edits — push or stash first. |
| `faa push`                 | main       | Commit your local tweaks onto the mirror so the agent can pull them. Aborts if the worktree has advanced — run `faa` to pull first.                                                                                                        |
| `faa reset`                | either     | "I'm done / scratch all this": declare the current state as truth, then run `faa reset sync` on the other side.                                                                                                                            |
| `faa reset sync`           | other side | Adopt the latest reset (a hard reset — discards local changes here; the old tip stays in the reflog).                                                                                                                                      |
| `faa -l`, `--list [N]`     | any        | List the last N worktrees in work (default 5).                                                                                                                                                                                             |
| `faa -p`, `--pick [N]`     | main       | List the last N and pick one (by number) to verify.                                                                                                                                                                                        |
| `faa -c`, `--checkout <B>` | main       | Verify feature branch `B` (creates/updates mirror `faa-B`).                                                                                                                                                                                |
| `faa -h`, `--help`         | any        | Show help.                                                                                                                                                                                                                                 |

### A typical session

```bash
# in the agent's worktree
faa                 # save the agent's work

# in main (dev server picks up faa-add-button)
faa                 # pull it in and run/verify it
# ...make a fix...
faa push            # send your fix back

# in the worktree
faa                 # agent pulls your fix and keeps going
```

## Install

`faa` is one file with no dependencies beyond git and the coreutils that ship
with **Git Bash**. Put it on your `PATH`:

```bash
cp faa /usr/bin/faa        # or any dir on PATH
chmod +x /usr/bin/faa
```

Then run `faa` from main or from any worktree.

## Notes

- **Topology:** worktrees of one repo (shared `.git`) created with
  `git worktree add`. No remotes/fetch involved — everything is local refs.
- **Mirror prefix:** `faa-` by default. Change it at the top of the script
  (`FAA_MIRROR_PREFIX`) or via the environment (`FAA_MIRROR_PREFIX=mir- faa`).
- **One rule:** feature branches must not start with the mirror prefix (they'd be
  mistaken for mirrors). faa errors out if they do.
- **Multiple features at once:** each gets its own mirror, so plain `faa` on main
  always follows the newest finished worktree (and `faa -c` jumps to a specific
  one). Each mirror keeps its own tweaks. Switching away from a feature with
  uncommitted edits is refused — `faa push` (or stash) them first.
- Commit messages are auto-generated (timestamp + changed files); this workflow
  treats them as throwaway. Use `faa reset` to bake the final state in.
