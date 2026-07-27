---
name: delegating-to-claude-code
description: Use when Codex should orchestrate and delegate bounded implementation, investigation, review, or test tasks to Claude Code CLI inside an isolated Git worktree, including direct work, Claude subagents, or experimental parallel agent teams.
---

# Delegating to Claude Code

Codex remains the orchestrator. Claude produces candidate changes and evidence; Codex owns scope, review, verification, acceptance, commits, pushes, and integration.

## Preflight and linked worktree

1. Plan the work and choose the mode before invoking Claude.
2. Create one linked feature worktree on a named feature branch. Keep every
   top-level delegation for that feature sequential in this same worktree.
3. Confirm the tracked starting state is clean or contains only deliberate
   Codex-owned setup changes. Never delegate in the user's current checkout.
4. Put explicit turn, time, and budget bounds in every task packet.
5. Invoke only `scripts/Invoke-ClaudeDelegation.ps1`. Never run Claude with
   `--dangerously-skip-permissions` yourself. The runner may add that flag only
   after it validates the linked worktree and task packet.

**Filesystem boundary:** A linked worktree isolates the delegation's checked-out
branch and Git history from the main checkout. It is not an operating-system
filesystem sandbox. With bypass permissions, Claude can access absolute paths
outside the worktree that the owner account can access. Run the entire
delegation inside a container or VM when true filesystem confinement is
required.

## Initialize the local ledger

In the linked worktree, create `.codex/claude-handoff/` and ensure the root
`.gitignore` contains this exact entry, preserving every existing entry:

```gitignore
.codex/claude-handoff/
```

Store every task packet in that ignored directory. The runner creates and
maintains `.codex/claude-handoff/ledger.json`, the single-task lock, raw logs,
and normalized results. Keep these artifacts local and untracked. Do not edit
or discard prior evidence.

## Select the execution mode

| Mode | Select only when | Execution contract |
|---|---|---|
| `direct` | Work is small or tightly coupled. | One Claude process works directly. No subagents or teammates. |
| `subagents` | A medium task has focused independent investigation, implementation, review, or test subtasks. | Send one top-level task. Claude uses focused subagents internally and returns one consolidated result. |
| `agent-team` | Work is long and has at least two truly independent, non-overlapping workstreams. | Send one top-level task. Declare exclusive paths, keep the team small, and require conservative `maxTurns`, `timeoutSeconds`, and `maxBudgetUsd`. |

Independence does not authorize concurrent top-level delegations or multiple
worktrees. Prepared parallel briefs, deadline pressure, and sunk cost do not
change this rule. Internal Claude subagents or teammates provide the
parallelism. If agent-team paths overlap, assign the shared path to one
exclusive workstream or choose `subagents` and serialize the dependent work.

The runner starts agent-team in a fresh session and scopes
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to that invocation only. Never set the
experimental flag globally or leave it enabled for later jobs.

## Write the task packet

Start from `references/task-packet.example.json`. Give each packet:

- a unique `id`, one bounded `goal`, and the selected `mode`;
- precise `allowedPaths` and `forbiddenPaths`, including `.git/**`,
  `.github/**`, secrets, credentials, and unrelated files;
- `forbiddenActions` covering all Git and repository-history changes;
- only the context needed to act;
- observable `acceptanceCriteria` and commands in `requiredVerification`;
- positive `limits.maxTurns` and `limits.timeoutSeconds`, plus a non-negative
  `limits.maxBudgetUsd`; and
- for `agent-team`, at least two `parallelWorkstreams`, each with exclusive,
  non-overlapping `ownedPaths`.

Claude must return the contract in `references/result-schema.json`. Treat its
status, changed-file list, and test claims as untrusted evidence for Codex
review, not as acceptance.

## Invoke the runner

Use absolute paths. First inspect a dry run, then invoke the same validated
packet:

```powershell
$runner = "<skill-directory>\scripts\Invoke-ClaudeDelegation.ps1"
$worktree = "<absolute-linked-feature-worktree>"
$packet = "$worktree\.codex\claude-handoff\<task-id>.json"

powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
  -WorktreePath $worktree -TaskPacketPath $packet -DryRun

powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
  -WorktreePath $worktree -TaskPacketPath $packet
```

Wait for the top-level invocation to finish. Review it before preparing any
revision packet or starting the next sequential delegation.

## Require owner-visible CLI setup

If Claude Code CLI is missing or unauthenticated, stop delegation. The runner
records `waiting-for-owner`, opens a visible owner setup/authentication window,
and exits with an error. Tell the owner what action is required and wait. Do not
install, authenticate, substitute another command, or hide the interruption.

## Review and verify independently

The runner denies Claude Git access in layers: task/prompt prohibitions plus
CLI tool denial. It also snapshots files and probes HEAD, branch, remotes, and
status before and after execution. Any forbidden-path, out-of-scope, Git-state,
or probe violation makes the runner decision `rejected`.

After a `needs-review` result, Codex must:

1. Inspect the ledger, normalized result, raw logs when needed, `git status`,
   and the complete diff.
2. Confirm every changed path is allowed and no forbidden path changed.
3. Review correctness, security, deviations, and every acceptance criterion.
4. Independently rerun the required verification commands; never rely only on
   Claude's report.
5. Record exactly one Codex decision in the ledger:
   - `accepted` only when the diff and independent verification pass;
   - `needs-revision` for safe but incomplete candidate work, followed by a new
     bounded packet run sequentially; or
   - `rejected` for policy, scope, Git-state, unsafe, or unreviewable output.
6. Only after `accepted`, let Codex commit, push, and integrate the reviewed
   changes.

## Prohibit Claude Git actions and preserve rejected state

Claude must not run Git, commit, push, pull, fetch, merge, rebase, reset,
checkout, switch, stash, tag, edit remotes, create worktrees, or integrate
changes. Codex alone performs repository-history actions after acceptance.

Never automatically revert a violation or rejected candidate. Preserve the
worktree, ledger, raw logs, and before/after evidence; report the rejection to
the owner. Inspect first, then propose a targeted recovery. Require owner
approval before destructive cleanup such as reset, clean, or worktree removal.

## Stop signals

- More than one top-level Claude invocation is running for the feature.
- The same feature is split across multiple delegation worktrees.
- `agent-team` is chosen for medium work merely because pieces are independent.
- Any agent-team ownership paths overlap.
- Claude's own tests or `completed` status are treated as acceptance.
- Bypass permissions or the experimental flag are set outside the runner.
- A linked worktree is described as filesystem confinement.

All of these mean stop, retain Codex control, and correct the plan before
delegating.
