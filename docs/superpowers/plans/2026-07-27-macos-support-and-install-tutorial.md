# macOS Support and Installation Tutorial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add genuine macOS support to the guarded Claude delegation runner and publish a detailed, terminal-first Windows and macOS installation tutorial.

**Architecture:** Retain one security-sensitive PowerShell runner and isolate host differences behind small platform and visible-terminal adapters. Keep the existing Windows deterministic suite, add a macOS end-to-end suite, run both in GitHub Actions, then update the skill instructions and README with verified platform-specific commands.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, Git, macOS Terminal and `open`, GitHub Actions, Markdown.

## Global Constraints

- Windows remains supported through Windows PowerShell 5.1 and `powershell`.
- macOS requires PowerShell 7 and invokes the runner through `pwsh`.
- Linux support is not part of this change.
- Keep one implementation of worktree, task-packet, ledger, Git-state, timeout, budget, and acceptance guards.
- Never pass `--dangerously-skip-permissions` to an installation or authentication terminal.
- Never interpolate task content, credentials, or reusable tokens into a setup script or shell command.
- Keep generated macOS setup scripts under the ignored `.codex/claude-handoff/` directory.
- Preserve Codex-only acceptance and Git ownership.
- Use current official Codex, Claude Code, PowerShell, Git, Apple, and Homebrew installation sources.
- The README must be terminal-first, numbered, beginner-friendly, and include copy/paste commands plus verification after each installation.

---

## File Structure

- Modify `delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1`
  - Own platform detection, path comparison, executable resolution, visible
    owner-setup launch specifications, and setup execution.
- Modify `tests/Invoke-ClaudeDelegation.Tests.ps1`
  - Preserve the Windows regression suite and add platform-adapter unit tests
    that can run without opening Terminal.
- Create `tests/Invoke-ClaudeDelegation.Mac.Tests.ps1`
  - Exercise the real macOS runner through `pwsh`, a linked Git worktree, and a
    deterministic fake Claude executable.
- Create `.github/workflows/test.yml`
  - Run the Windows and macOS suites on their native hosted runners.
- Modify `delegating-to-claude-code/SKILL.md`
  - Teach Codex to select `powershell` on Windows and `pwsh` on macOS.
- Modify `README.md`
  - Publish detailed Windows/macOS setup, first-use, update, uninstall, and
    troubleshooting procedures.

---

### Task 1: Platform-Aware Path and Host Primitives

**Files:**
- Modify: `delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1:18-173`
- Modify: `tests/Invoke-ClaudeDelegation.Tests.ps1:1-260`

**Interfaces:**
- Produces: `Get-DelegationPlatform() -> "Windows" | "MacOS"`
- Produces: `Get-PathStringComparison([string] $Platform) -> [System.StringComparison]`
- Produces: `Test-CanonicalPathEqual([string] $Left, [string] $Right, [string] $Platform) -> [bool]`
- Consumed by: worktree, ledger, scope, sibling-worktree, and task-packet path checks.

- [ ] **Step 1: Add failing platform/path tests**

Add assertions that explicitly pass platform names:

```powershell
Assert-True (Test-CanonicalPathEqual 'C:\Repo\Feature' 'c:\repo\feature' 'Windows') `
  'Windows canonical paths must compare case-insensitively'
Assert-True (-not (Test-CanonicalPathEqual '/Users/dev/Repo' '/users/dev/repo' 'MacOS')) `
  'macOS canonical paths must compare ordinally'
Assert-True ((Get-PathStringComparison 'Windows') -eq [StringComparison]::OrdinalIgnoreCase) `
  'Windows path comparison is wrong'
Assert-True ((Get-PathStringComparison 'MacOS') -eq [StringComparison]::Ordinal) `
  'macOS path comparison is wrong'
```

- [ ] **Step 2: Run the focused suite and confirm RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Invoke-ClaudeDelegation.Tests.ps1
```

Expected: FAIL because the three platform functions do not exist.

- [ ] **Step 3: Implement host primitives**

Add:

```powershell
function Get-DelegationPlatform {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'Windows' }
    if ($IsMacOS) { return 'MacOS' }
    throw 'Unsupported platform. This skill supports Windows and macOS.'
}

function Get-PathStringComparison([string]$Platform = (Get-DelegationPlatform)) {
    switch ($Platform) {
        'Windows' { return [StringComparison]::OrdinalIgnoreCase }
        'MacOS' { return [StringComparison]::Ordinal }
        default { throw "Unsupported platform: $Platform" }
    }
}

function Test-CanonicalPathEqual(
    [string]$Left,
    [string]$Right,
    [string]$Platform = (Get-DelegationPlatform)
) {
    return $Left.Equals($Right, (Get-PathStringComparison $Platform))
}
```

Replace path-identity uses of hard-coded `OrdinalIgnoreCase` with the helper.
Retain case-insensitive comparison for normalized Git path patterns because
task scopes are policy patterns, not host path identities.

- [ ] **Step 4: Run the complete Windows suite**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Invoke-ClaudeDelegation.Tests.ps1
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```powershell
git add delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1 `
  tests/Invoke-ClaudeDelegation.Tests.ps1
git commit -m "feat: add platform-aware runner primitives"
```

---

### Task 2: Cross-Platform Visible Owner Setup

**Files:**
- Modify: `delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1:375-430`
- Modify: `tests/Invoke-ClaudeDelegation.Tests.ps1:400-525`

**Interfaces:**
- Produces: `ConvertTo-PosixSingleQuotedString([string]) -> [string]`
- Produces: `New-MacOwnerSetupScriptContent([string] $Worktree, [bool] $Installed) -> [string]`
- Produces: `New-OwnerSetupLaunchSpec([string] $Worktree, [string] $StateDirectory, [bool] $Installed, [string] $Platform) -> [pscustomobject]`
- Changes: `Show-OwnerSetup` accepts `StateDirectory` and executes the returned launch specification.

- [ ] **Step 1: Add failing launch-spec tests**

Cover both platform branches without opening a window:

```powershell
$windows = New-OwnerSetupLaunchSpec $linked $state.stateDir $true 'Windows'
Assert-True ($windows.FilePath -eq 'powershell') 'Windows setup launcher changed'
Assert-True ((@($windows.ArgumentList) -join ' ') -match 'claude') `
  'Windows auth setup does not launch Claude'

$mac = New-OwnerSetupLaunchSpec "/Users/O'Brien/Feature Work" $state.stateDir $false 'MacOS'
Assert-True ($mac.FilePath -eq 'open') 'macOS setup must use open'
Assert-True ($mac.ArgumentList[0] -eq '-a' -and $mac.ArgumentList[1] -eq 'Terminal') `
  'macOS setup must open Terminal'
Assert-True ($mac.SetupScriptPath.StartsWith($state.stateDir)) `
  'macOS setup script escaped the ignored handoff directory'
Assert-True ($mac.SetupScriptContent -match "O'\"'\"'Brien") `
  'macOS setup did not safely quote an apostrophe'
Assert-True ($mac.SetupScriptContent -notmatch 'dangerously-skip-permissions') `
  'macOS setup received bypass permissions'
```

Also cover installed and missing Claude for Windows and macOS.

- [ ] **Step 2: Run the Windows suite and confirm RED**

Run the existing suite. Expected: FAIL because launch-spec functions and the
new `StateDirectory` parameter are absent.

- [ ] **Step 3: Implement safe macOS script construction**

Use single-quote-safe POSIX data quoting:

```powershell
function ConvertTo-PosixSingleQuotedString([string]$Value) {
    return "'" + $Value.Replace("'", "'`"`"'`"`'") + "'"
}
```

Build a `.command` script containing only fixed instructions and the quoted
worktree path. For missing Claude, end with:

```sh
exec "${SHELL:-/bin/zsh}" -l
```

For installed but unauthenticated Claude, start `claude`, instruct the owner to
use `/login`, and leave the shell interactive after Claude exits.

- [ ] **Step 4: Implement launch specifications**

Return objects with:

```powershell
[pscustomobject]@{
    FilePath = 'open'
    ArgumentList = @('-a', 'Terminal', $setupScriptPath)
    WorkingDirectory = $Worktree
    SetupScriptPath = $setupScriptPath
    SetupScriptContent = $content
}
```

For Windows, return the existing `powershell -NoExit` behavior. In
`Show-OwnerSetup`, write the macOS script as UTF-8 without BOM, execute
`chmod` with `700` and the canonical absolute script path as separate native
arguments without shell interpolation, then launch the returned specification.
Do not place `--` after the mode: macOS BSD `chmod` treats it as a filename.

- [ ] **Step 5: Update all owner-setup call sites**

Pass `$State.stateDir` from preflight failure handling. Confirm ledger status is
written before the window opens and the runner exits without launching Claude
with bypass permissions.

- [ ] **Step 6: Run the complete Windows suite**

Expected: exit 0 with installed/missing setup cases passing for both platform
specifications.

- [ ] **Step 7: Commit**

```powershell
git add delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1 `
  tests/Invoke-ClaudeDelegation.Tests.ps1
git commit -m "feat: open owner setup on macOS"
```

---

### Task 3: macOS End-to-End Runner Test

**Files:**
- Create: `tests/Invoke-ClaudeDelegation.Mac.Tests.ps1`
- Modify: `delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1`

**Interfaces:**
- Consumes: public runner parameters `WorktreePath`, `TaskPacketPath`,
  `ClaudeCommand`, `DryRun`, and `LibraryMode`.
- Produces: a native macOS regression command:
  `pwsh -NoProfile -File ./tests/Invoke-ClaudeDelegation.Mac.Tests.ps1`.

- [ ] **Step 1: Create a failing macOS fixture**

The test must refuse to run on non-macOS hosts and, on macOS:

1. create a disposable Git repository and named linked worktree;
2. configure local test-only Git identity;
3. create a POSIX fake `claude` executable with `chmod 700`;
4. answer `auth status` with `{"loggedIn":true}`;
5. answer `--version` with a supported version;
6. consume the prompt from standard input;
7. write the expected normalized result JSON; and
8. perform one allowed edit.

Use `try/finally` to remove only the resolved disposable fixture.

- [ ] **Step 2: Run on a macOS host and confirm RED**

Run:

```bash
pwsh -NoProfile -File ./tests/Invoke-ClaudeDelegation.Mac.Tests.ps1
```

Expected before compatibility fixes: FAIL at the first remaining
Windows-specific process or path assumption.

- [ ] **Step 3: Remove remaining Windows-only assumptions**

Keep changes minimal. Resolve executables as native applications, use
`[IO.Path]::DirectorySeparatorChar` where a host path is required, and continue
normalizing Git/task policy paths to `/`. Do not introduce shell execution of
the task prompt.

- [ ] **Step 4: Prove macOS dry-run and execution behavior**

Assertions must verify:

- nested worktree paths reject;
- dry-run contains `--dangerously-skip-permissions` only in the validated
  Claude invocation;
- the allowed edit yields `needs-review`;
- result and ledger contracts are valid;
- current branch, HEAD, remotes, index, refs, configs, and sibling worktrees
  remain unchanged; and
- no setup terminal is opened during an authenticated run.

- [ ] **Step 5: Run both platform suites**

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Invoke-ClaudeDelegation.Tests.ps1
```

macOS:

```bash
pwsh -NoProfile -File ./tests/Invoke-ClaudeDelegation.Mac.Tests.ps1
```

Expected: both exit 0 on their native hosts.

- [ ] **Step 6: Commit**

```bash
git add delegating-to-claude-code/scripts/Invoke-ClaudeDelegation.ps1 \
  tests/Invoke-ClaudeDelegation.Mac.Tests.ps1
git commit -m "test: cover macOS delegation end to end"
```

---

### Task 4: Windows and macOS Continuous Integration

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: the two platform-native test commands from Tasks 1-3.
- Produces: release checks on `windows-latest` and `macos-latest`.

- [ ] **Step 1: Add the workflow**

Create:

```yaml
name: test

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Windows delegation tests
        shell: powershell
        run: >
          powershell -NoProfile -ExecutionPolicy Bypass
          -File .\tests\Invoke-ClaudeDelegation.Tests.ps1

  macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify PowerShell
        run: pwsh --version
      - name: Run macOS delegation tests
        shell: pwsh
        run: ./tests/Invoke-ClaudeDelegation.Mac.Tests.ps1
```

- [ ] **Step 2: Validate workflow syntax locally**

Parse the YAML with an available YAML parser and confirm:

- only read repository permission is granted;
- no secrets are requested;
- each job runs only its native test; and
- every action is pinned to a version tag.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: test Windows and macOS runners"
```

---

### Task 5: Teach the Skill Both Invocation Paths

**Files:**
- Modify: `delegating-to-claude-code/SKILL.md:1-159`
- Test: `tests/skill-behavior-scenarios.md`

**Interfaces:**
- Consumes: the supported runner commands from Tasks 1-3.
- Produces: explicit host selection instructions for Codex.

- [ ] **Step 1: Add a behavioral scenario**

Add a scenario where a MacBook owner requests delegation and the evaluator
requires:

- one named linked feature worktree;
- `pwsh`, not `powershell`;
- the same guarded runner;
- visible Terminal owner setup when required; and
- unchanged Codex acceptance/Git ownership.

- [ ] **Step 2: Update the skill instructions**

Add a platform table:

| Host | Runner command | Owner setup |
|---|---|---|
| Windows | `powershell -NoProfile -ExecutionPolicy Bypass -File ...` | Windows PowerShell |
| macOS | `pwsh -NoProfile -File ...` | macOS Terminal |

State that unsupported hosts must stop rather than improvise another runner.

- [ ] **Step 3: Run skill validation**

Run:

```powershell
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  ".\delegating-to-claude-code"
```

Expected: `Skill is valid!`

- [ ] **Step 4: Commit**

```bash
git add delegating-to-claude-code/SKILL.md tests/skill-behavior-scenarios.md
git commit -m "docs: teach cross-platform delegation"
```

---

### Task 6: Publish the Detailed Terminal-First Tutorial

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: official installation commands and the finished platform behavior.
- Produces: one public tutorial usable without reading implementation files.

- [ ] **Step 1: Recheck official commands**

Verify immediately before editing:

- Codex installation and `codex login` in the current Codex manual;
- user skill location `~/.agents/skills`;
- Claude native installation and first-run browser login in
  `https://code.claude.com/docs/en/quickstart`;
- PowerShell macOS installation in current Microsoft documentation; and
- Homebrew commands in current Homebrew documentation.

- [ ] **Step 2: Replace the short install section**

Write a numbered Windows procedure with copy/paste PowerShell commands:

```powershell
winget install --id Git.Git -e
irm https://chatgpt.com/codex/install.ps1 | iex
codex --version
codex login
codex login status
irm https://claude.ai/install.ps1 | iex
claude --version
claude
```

Then clone and install:

```powershell
git clone https://github.com/admworx88/codex-claude-delegation-skill.git
$skillsRoot = Join-Path $HOME '.agents\skills'
$source = Join-Path $PWD 'codex-claude-delegation-skill\delegating-to-claude-code'
$destination = Join-Path $skillsRoot 'delegating-to-claude-code'
New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
Copy-Item -Recurse -Force -LiteralPath $source -Destination $destination
Test-Path (Join-Path $destination 'SKILL.md')
```

Explain that `True` confirms the primary skill file exists.

- [ ] **Step 3: Add the macOS procedure**

Use Terminal commands:

```bash
xcode-select --install
git --version
brew install --cask powershell
pwsh --version
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
codex login
codex login status
curl -fsSL https://claude.ai/install.sh | bash
claude --version
claude
```

Then clone and install:

```bash
git clone https://github.com/admworx88/codex-claude-delegation-skill.git
mkdir -p "$HOME/.agents/skills"
cp -R \
  "./codex-claude-delegation-skill/delegating-to-claude-code" \
  "$HOME/.agents/skills/"
test -f "$HOME/.agents/skills/delegating-to-claude-code/SKILL.md" \
  && echo "Skill installed"
```

If Homebrew itself is absent, link to the official installer instead of
silently assuming it exists.

- [ ] **Step 4: Add discovery and first-use steps**

Tell users to restart Codex, enter their Git repository, start `codex`, and
type this inside the Codex prompt—not in the shell:

```text
$delegating-to-claude-code

Fix the CSV export bug. Keep Codex as orchestrator. Let Codex choose the
delegation mode, independently verify Claude's work, and perform all Git
operations only after acceptance.
```

Describe expected milestones: worktree creation, task packet, Claude run,
`needs-review`, independent tests, and Codex decision.

- [ ] **Step 5: Add mode examples**

Include complete prompts for direct, subagents, and agent-team. Label
agent-team experimental and require non-overlapping owned paths.

- [ ] **Step 6: Add update and uninstall commands**

Use exact destinations and warn before replacement/removal. On both platforms,
make a timestamped backup of the installed skill before replacing it. Do not
suggest broad deletion of `.agents`, `.codex`, the repository root, or the
user's home directory.

- [ ] **Step 7: Add troubleshooting**

For every required command, include:

- a verification command;
- the expected success signal;
- command-not-found/PATH recovery;
- login recovery;
- incorrect nested install detection;
- macOS Terminal/open and executable-permission recovery; and
- safe delegation rejection recovery.

- [ ] **Step 8: Review documentation safety and consistency**

Confirm:

- all skill locations use `.agents/skills`;
- Windows uses `powershell`;
- macOS uses `pwsh`;
- authentication uses browser-supported interactive flows;
- no credentials appear in commands;
- no command gives Claude Git ownership; and
- the worktree-not-sandbox warning remains prominent.

- [ ] **Step 9: Commit**

```bash
git add README.md
git commit -m "docs: add Windows and macOS setup tutorial"
```

---

### Task 7: Release Verification and Review

**Files:**
- Verify: all tracked files changed by Tasks 1-6.

**Interfaces:**
- Consumes: complete implementation.
- Produces: release evidence for merge and publication.

- [ ] **Step 1: Run Windows tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Invoke-ClaudeDelegation.Tests.ps1
```

Expected: exit 0.

- [ ] **Step 2: Run macOS tests in CI**

Push the feature branch only after local review, then require the
`macos-latest` job to pass. Do not claim native macOS support from Windows-only
tests.

- [ ] **Step 3: Validate the skill and public files**

```powershell
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  ".\delegating-to-claude-code"
git diff --check main...HEAD
git status --short
```

Expected: validator prints `Skill is valid!`, diff check exits 0, and status is
clean.

- [ ] **Step 4: Run tracked-file and secret checks**

Confirm `.codex/claude-handoff/`, local test artifacts, credentials, tokens,
and temporary setup scripts are not tracked.

- [ ] **Step 5: Request independent review**

Review along two axes:

- specification compliance: every macOS/runtime/tutorial requirement; and
- code quality/security: quoting, path identity, process launch, Git guards,
  setup artifacts, and no bypass leakage.

Resolve every Critical or Important finding and rerun the complete relevant
suite.

- [ ] **Step 6: Integrate only after native checks pass**

Use the branch-finishing workflow. Merge to `main` only after the user selects
the integration option and both native CI jobs pass. Verify the merged result,
push without force, and confirm remote `main` matches the local release commit.
