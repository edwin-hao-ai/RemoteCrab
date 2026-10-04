docs: 5880055 carries two sessions' work under one message

`5880055` is titled for the speaker row, and it is the other session's commit.
It also contains all of this session's preview-corruption work, because that
session ran `git commit` while these files were staged here:

- docs/HANDOFF-MAC-SIDE-2026-10-04.md (new) — the Mac handoff
- memories/2026-10-04-windows-preview-corruption.md (new)
- docs/lessons/windows.md — lessons 116-118
- AGENTS.md — the handoff table row and rule 0
- windows/crates/rc-protocol/src/wire.rs — kind 0x25 requestKeyframe + tests
- windows/crates/rc-app/src/main.rs — keyframe request, claimed-vs-measured
- windows/crates/rc-app/src/status.rs — stream_shortfall + tests

History is not rewritten: the commit is already on origin and the other session
is actively pushing to this branch, so amending it would be more dangerous than
the misleading message. This note exists so nobody reads `5880055` as speaker-
only and assumes the preview work is still unmerged.

The combined tree is verified as one unit: build clean, 533 tests pass, clippy
-D warnings clean, renderer_fidelity exits 0.

The race itself is the lesson, and it is the same shape as lesson 118's. Two
sessions in one working tree will eventually stage each other's files, because
`git add` is not scoped to an author. A worktree per session prevents it; a
shared tree detects it only if someone reads the diff before committing.
