# macOS Support and Installation Tutorial Design

## Goal

Make `delegating-to-claude-code` genuinely usable on macOS while preserving
the existing Windows behavior and security contracts. Expand the public
README into a terminal-first, beginner-friendly installation and first-use
tutorial for Windows and macOS.

## Supported platforms

- Windows continues to support Windows PowerShell 5.1 through `powershell`.
- macOS supports PowerShell 7 through `pwsh`.
- Linux support is not part of this change.

Both supported platforms use the same guarded PowerShell runner. Platform
adapters may vary only where the host must resolve paths, open a visible
terminal, or launch platform-specific commands.

## Cross-platform runner

The existing runner remains the single implementation of:

- linked-worktree validation;
- task-packet and mode validation;
- ignored ledger and session continuity;
- Git and filesystem fingerprints;
- Git command denial;
- process limits, retries, logs, and result validation; and
- Codex review and acceptance boundaries.

Path equality must use the host's filesystem semantics: case-insensitive on
Windows and ordinal on macOS. Paths passed to Git, Claude, fingerprints, and
ledger identity checks must remain canonical absolute paths.

The runner must resolve native executable forms on both platforms. Windows
`.cmd` support remains intact. macOS executables and scripts must be launched
without shell interpolation of task content.

## Visible owner setup

Owner installation and authentication remain visible and interactive.
The runner must record `waiting-for-owner` and stop the delegation before
opening the setup terminal.

### Windows

Retain the current visible Windows PowerShell setup window. It must never
receive the bypass-permissions flag.

### macOS

Create a uniquely named `.command` script under the ignored
`.codex/claude-handoff/` directory, mark it executable, and open it with the
macOS Terminal application. The script must:

1. change to the exact linked-worktree root using safely quoted data;
2. explain whether Claude is missing or authentication is required;
3. leave the Terminal session interactive for installation or login;
4. direct an unauthenticated owner to start Claude and use `/login`;
5. tell the owner to close the window and ask Codex to retry; and
6. never include `--dangerously-skip-permissions`.

The generated setup script is local evidence and remains ignored. It must not
contain task content, secrets, credentials, or reusable authentication tokens.

## Test strategy

Refactor platform selection and owner-setup launch construction into
deterministic functions that can be inspected without opening a real window.

Tests must cover:

- Windows and macOS runner selection;
- Windows `.cmd` and macOS executable resolution;
- platform-aware path comparison;
- safely quoted macOS worktree paths, including spaces and apostrophes;
- missing-Claude and unauthenticated-Claude setup flows on both platforms;
- absence of the bypass flag from every setup command;
- preservation of all existing worktree, packet, ledger, Git, timeout, and
  result-contract tests; and
- rejection behavior without automatic reversion.

A GitHub Actions workflow must run the supported test suite on
`windows-latest` and `macos-latest`. The macOS job installs PowerShell 7 when
the hosted image does not already provide `pwsh`.

## README tutorial

The README remains the single public entry point. It must use numbered,
copy/pasteable terminal steps and explain what each command does.

### Windows procedure

Include commands to:

1. install or verify Git;
2. install or verify Codex CLI;
3. authenticate Codex and check login status;
4. install or verify Claude Code CLI;
5. authenticate Claude interactively;
6. clone this repository;
7. create `%USERPROFILE%\.agents\skills`;
8. copy the complete skill directory;
9. verify `SKILL.md`, scripts, and references;
10. restart Codex and confirm skill discovery; and
11. run a first delegation.

### macOS procedure

Include commands to:

1. install or verify Apple command-line tools and Git;
2. install PowerShell 7 and verify `pwsh`;
3. install Codex CLI using the current official installer;
4. run `codex login` and verify login status;
5. install Claude Code using Anthropic's recommended native installer;
6. run `claude`, complete browser authentication, and verify the session;
7. clone this repository;
8. create `~/.agents/skills`;
9. copy the complete skill directory;
10. verify `SKILL.md`, scripts, and references;
11. restart Codex and confirm skill discovery; and
12. run a first delegation with `pwsh`.

Where a package-manager alternative is included, label one method as the
recommended default and explain update behavior. Commands and links must come
from current official Codex, Claude Code, PowerShell, Git, Apple, or Homebrew
sources.

## First-use examples

Provide complete prompts for:

- `direct`: a small, tightly coupled fix;
- `subagents`: a medium task with bounded internal investigation,
  implementation, and tests; and
- `agent-team`: a long task with independent, non-overlapping ownership.

Explain that Codex chooses the mode, creates one feature worktree, keeps
top-level Claude invocations sequential, reviews the diff, reruns tests, and
alone performs Git operations and acceptance.

## Updating, uninstalling, and troubleshooting

Document platform-specific commands for updating the cloned repository,
reinstalling the skill files, and removing only the exact installed skill
directory.

Troubleshooting must cover:

- `git`, `codex`, `claude`, `powershell`, or `pwsh` not found;
- Codex or Claude authentication failure;
- skill not appearing after installation;
- accidental extra directory nesting;
- macOS execution or quarantine/permission errors;
- Terminal setup window not opening;
- worktree or task-packet validation failures; and
- safe recovery from a rejected delegation without automatic reset or clean.

## Security communication

Keep the bypass-permissions warning before the installation tutorial. State
plainly that a linked Git worktree is not an operating-system sandbox and that
Claude can reach owner-accessible absolute paths. Recommend a container or
virtual machine for true filesystem confinement.

The tutorial must not tell users to expose credentials, place secrets in task
packets, disable host security controls, or let Claude commit, push, merge, or
accept its own work.

## Acceptance criteria

- The runner works through `powershell` on Windows and `pwsh` on macOS.
- Missing or unauthenticated Claude opens an owner-visible interactive terminal
  on the current platform and exits the delegation as `waiting-for-owner`.
- Existing security and repository-state guards remain enforced.
- Windows and macOS CI jobs pass deterministically.
- The README contains complete terminal-first installation, verification,
  first-use, update, uninstall, and troubleshooting procedures.
- All published commands are checked against current official documentation.

