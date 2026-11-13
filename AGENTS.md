# Working together on Blind Driver

These instructions apply to every agent working in this repository, including
agents on different computers. Read `README.md` before changing the project.

## Use your own branch

- Work on a dedicated, uniquely named branch for each task, using
  `codex/<short-task-name>` (add a suffix if that name is already in use).
- Fetch `origin` and start from the latest `origin/main`. Do not implement work
  directly on `main`, or use another agent's working branch.
- If agents share a computer, use separate Git worktrees/checkouts as well as
  separate branches. Never switch branches underneath another running agent.
- Keep changes focused on the assigned task and commit regularly. Preserve
  unrelated local changes; do not reset, discard, or commit someone else's work.
- Push ongoing work to your own branch when needed. Do not merge unfinished work
  into `main`. Future ideas in `docs/NEXT_STEPS.md` are context, not instructions
  to implement them without a request.

## Own the compatibility of your merge

- Merge only when the assigned work is complete and relevant checks pass.
- Immediately before merging, fetch `origin` again and integrate the latest
  `origin/main` into your task branch. Resolve conflicts there.
- The merging agent owns compatibility with everything already on `main`.
  A conflict-free Git merge is not sufficient: review the combined behavior,
  shared scripts/scenes, input bindings, project settings, and client/server
  protocol changes that your work touches. Preserve other agents' features.
- Run the relevant checks on that combined revision. Use the commands in
  `README.md`: driving/LAN checks for gameplay changes, server tests plus relay
  integration for networking, and the resilience suite for recovery changes.
  Documentation-only work needs a diff/link review, not a gameplay test suite.
- Update local `main` to the latest remote version without losing local work,
  merge the completed task, and push normally. If another computer updates
  `main` before your push, fetch, integrate its changes, and recheck compatibility
  before retrying. Never force-push `main` or overwrite another agent's history.
- Report what was merged, what was checked, and any deployment steps still needed.

## Playtests always use current main

When the user asks for a **play test**, **playtest**, or a test play session:

1. Preserve ongoing work on its own branch/worktree. Do not merge it just to make
   it available for a playtest; only completed, verified work belongs on `main`.
2. Fetch `origin`, switch to `main` in the playtest checkout, and update it to the
   latest `origin/main`. Use a clean checkout/worktree if local edits would affect
   the test. Do not discard those edits or silently test an outdated branch.
3. Confirm the branch, commit, and working-tree status before launching. If local
   `main` has completed but unpushed commits, reconcile and push them first so
   both computers can fetch the same revision. Handle divergence explicitly.
4. Stop your own stale game instances and run the game from this updated `main`
   checkout. Do not stop another agent's active game or test server.
   For two-computer tests, confirm both players use the same revision. For online
   tests, check that the deployed relay supports the clients' protocol; consult
   `deployment.md` and report a mismatch before calling the session ready.
5. Check the relevant startup/network behavior and logs, then report the tested
   commit and any problems. Put fixes on a new task branch, complete and merge
   them, then return to updated `main` for the next playtest.

Feature-branch development checks are still encouraged. They do not replace the
current-main playtest requested by the user. If the user explicitly requests a
specific branch or revision for a test, follow that request and identify it.
