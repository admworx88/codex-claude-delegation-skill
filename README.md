# Codex → Claude Code Delegation Skill

A Codex skill for delegating bounded coding tasks to Claude Code CLI while
keeping Codex in charge of the complete workflow.

Codex plans the work, selects the delegation mode, defines scope, reviews the
diff, reruns verification, accepts or rejects the result, and performs every
commit, push, and integration step. Claude is a worker: it may edit only the
assigned files and returns candidate changes and evidence for Codex to review.

## Important security warning

This skill launches Claude with `--dangerously-skip-permissions`.

A linked Git worktree isolates the feature branch and Git history from the
main checkout. **It is not an operating-system or filesystem sandbox.** Claude
still runs with the owner's account permissions and can reach accessible
absolute paths outside the worktree. Use a container or virtual machine around
the entire delegation workflow when true filesystem confinement is required.

The runner adds the bypass flag only after validating a linked worktree and
task packet. Claude is also instructed and guarded against Git operations, but
these controls do not turn the host account into a security boundary. Never
include secrets in task packets or the local ledger.

## Prerequisites

- Windows with Windows PowerShell 5.1 or PowerShell 7
- Git with linked-worktree support
- Codex with local skill support
- [Claude Code CLI](https://code.claude.com/docs/en/installation)
  installed and authenticated by the owner
- A Git repository where each feature or bug can use a named feature branch

If Claude is missing or needs authentication, the runner records
`waiting-for-owner`, opens a visible PowerShell window, and stops. The owner
installs or signs in interactively, closes that window, and then asks Codex to
retry. The skill does not install Claude or authenticate on the owner's behalf.

## Install

Clone or download this repository, then copy the complete
`delegating-to-claude-code` folder into the Codex skills directory:

```powershell
$source = "<repository>\delegating-to-claude-code"
$destination = Join-Path $HOME ".codex\skills\delegating-to-claude-code"
Copy-Item -Recurse -Force -LiteralPath $source -Destination $destination
```

Restart Codex if the skill is not discovered in the current session.

## Use

Ask Codex to delegate a feature or bug fix, for example:

> Use the delegating-to-claude-code skill. Keep Codex as orchestrator and
> delegate implementation of the CSV export bug to Claude Code.

Codex creates or selects one linked feature worktree and keeps all top-level
Claude tasks for that feature sequential in that same worktree. Claude never
commits, pushes, merges, accepts its own output, or integrates changes. Codex
independently reviews and verifies each candidate before accepting it.

### Delegation modes

| Mode | Intended use |
| --- | --- |
| `direct` | A small change or tightly coupled work performed by the primary Claude session. |
| `subagents` | A medium task with a few bounded, independent subtasks coordinated inside one top-level Claude invocation. |
| `agent-team` | A long task with at least two independent, non-overlapping workstreams and exclusive path ownership. This mode is experimental and uses a fresh team-scoped session. |

Codex alone chooses the mode. Duration by itself does not justify parallelism;
dependent or overlapping work remains sequential.

## Worktree and local ledger

The guarded runner refuses the repository's main checkout and validates the
repository, worktree, branch, and task packet before launching Claude. It also
prevents concurrent top-level Claude tasks in the same worktree and checks
HEAD, branch, remotes, file changes, and forbidden paths after execution.

Each feature keeps durable handoff state under:

```text
.codex/claude-handoff/
```

That folder contains task packets, a ledger, locks, raw output, normalized
results, Git-state evidence, and review decisions. It stays local and ignored
by Git. Session continuity helps direct and subagent runs, but the ledger is
the durable source of context.

## Validate and test

From the repository root:

```powershell
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  ".\delegating-to-claude-code"

powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\tests\Invoke-ClaudeDelegation.Tests.ps1"
```

The deterministic test suite substitutes a fake Claude executable, so it does
not require live Claude credentials. A real smoke test is optional and should
run only after the owner has installed and authenticated Claude.

## License

[MIT](LICENSE) © 2026 Aljon Moliva
