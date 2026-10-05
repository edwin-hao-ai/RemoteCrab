# Two machines, one repository: the working agreement

Written 2026-10-05, after a session in which two commits on this machine ended
up with each other's content. Nothing was lost and nothing broke — the damage
was to the *record*, which is the part that is expensive to repair later because
it silently misattributes every future bisect, revert and code review.

## What actually happened

The Mac and Windows sessions both work out of the same clone, sometimes at the
same time. Three separate mechanisms then interfered:

| # | Mechanism | What it did |
|---|---|---|
| 1 | **One shared index** | A parallel session staged its 6 doc files between my `git add` and my `git commit`. My commit message described a notification feature; the content was its docs. |
| 2 | **One shared HEAD** | It committed while my 9 files were staged, so my code went into a commit titled `fix(window): stop minifb painting from a freed buffer`. |
| 3 | **`git checkout stash@{0} -- <file>`** | The standard way to restore a conflicted file. It **stages** it. The next plain `git commit` — which I believed only contained the file I had just `git add` — swept it in. |

A fourth, on the other machine: `git stash` + `git reset` emptied the tree
mid-task. Tracked edits survived only because of that stash; untracked files were
the sole survivors, and a commit then referenced them by name, so HEAD did not
compile for anyone cloning it.

## The rules that would have prevented all four

**1. One worktree per task, always.** Not per session — per *task*. Two agents
in two worktrees have two indexes and two HEADs, so none of #1, #2 or #3 can
happen. `git worktree add ../iBridge-<task> -b <task>/<slug>`.

```sh
git worktree list                       # what exists
git worktree remove ../iBridge-<task>   # when done (delete the branch too)
```

**2. Never commit from the main clone.** The main clone is for reading,
building and merging. If you are about to edit, make a worktree. This is the
single rule that removes most of the risk.

**3. Stage and commit in one command.** The window between `git add` and
`git commit` is the dangerous one, and it is entirely avoidable:

```sh
git add path/to/one/thing && git commit -m "…"
```

**4. After restoring a file from a stash, check what is staged.**
`git checkout stash@{0} -- <file>` stages it. `git status --short` shows `M ` for
staged and ` M` for not — the column is the whole difference.

**5. One branch per machine.** `mac/*` and `windows/*`. `main` is only ever
moved by a merge, and the merge is where the overlap check belongs:

```sh
git diff --name-only main...HEAD | sort > /tmp/mine
git diff --name-only $(git merge-base main HEAD)..origin/main | sort > /tmp/theirs
comm -12 /tmp/mine /tmp/theirs        # must be empty, or read the conflict first
```

**6. Read the stat before pushing.**

```sh
git show --stat HEAD | tail
```

A file count that does not match your message is the only cheap signal that the
commit is not what you think it is. It caught one of the two incidents.

## The guard in the repo

`.githooks/pre-commit` refuses a commit whose staged set holds more than two
files, and prints the set so you can see what you did not put there. It exists
because of #1 and #3 — the commit picked up files that were already staged.

```sh
git config core.hooksPath .githooks    # ← each machine, once
```

Merges and `--no-verify` are exempt. `REMOTECRAB_SKIP_STAGED_GUARD=1` is the
hatch, for the commits that really are meant to be wide.

It is deliberately a *prompt*, not a rule. A guard that fires on legitimate work
gets disabled within a day, and a disabled guard is indistinguishable from no
guard at all.

## Backups: what actually survived

Measured, not assumed. After every incident above, this audit found **nothing
lost**:

```sh
git rev-list --all --reflog | sort -u > /tmp/all
git rev-list origin/main | sort -u  > /tmp/inmain
comm -23 /tmp/all /tmp/inmain                      # commits main does not have
git cherry origin/main <that-commit>               # + = patch genuinely absent
```

Seven commits were unreachable from any ref. Six turned out to be delivered by
*other* commits (`git cherry` showed their patches already applied). One was a
deliberate replacement — an incorrect fix of mine, superseded by the correct one.
Two more were historical: a rename the project later partially reversed on
purpose, and a build-configuration change from before the signing work.

`git cherry` is the test that matters. "Is this commit referenced?" is the wrong
question — a commit can be unreachable while its content is on `main` by another
route. "Is its *patch* on `main`?" is the question that answers "did we lose
code?"

### Why the stash was the most durable thing here

Both stashes survived every concurrent `git reset`, because **a stash is a
ref**, and `git reset` moves `HEAD` and the branch — it does not touch refs
named `refs/stash`. Ten minutes of commits came and went; the stash from an
earlier session was still intact at the end.

That is the argument for the habit, not for `git stash` as a workflow:

```sh
git stash push -m "what this is, and why" -- <the paths you touched>
```

A named stash is the cheapest backup in git, and this repo has one from the
Windows session that has now outlived several commits.

### What is not a backup

* **Untracked files.** No ref points at them. `git stash` without `-u` skips
  them, and a `reset --hard` deletes them.
* **The index.** It is shared mutable state with no history of its own. If two
  agents share a clone, the index is the first thing that stops being yours.
* **Anything older than the reflog window.** Unreachable commits survive until
  `git gc` prunes them. For work that matters, push it.

## The one thing that makes concurrency safe here

Both machines push to the same `origin`, and `git` refuses a non-fast-forward
push. **Nothing was ever silently overwritten**, in any incident above. The
failures were all local and all recoverable. The risk is not data loss — it is a
commit whose content contradicts its message, surviving long enough to be
trusted.
