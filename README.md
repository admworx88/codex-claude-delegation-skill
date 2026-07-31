# Codex -> Claude Code Delegation Skill

A Codex skill that delegates bounded coding work to Claude Code CLI while
keeping Codex in charge of planning, scope, review, verification, acceptance,
and every Git operation.

Codex creates or selects one linked feature worktree and sends Claude a
guarded task packet. Claude may change only the allowed files and returns
candidate work for Codex to review. Claude never commits, pushes, merges, or
accepts its own output.

## Important security warning

This skill launches Claude with `--dangerously-skip-permissions`.

A linked Git worktree isolates the feature branch and Git history from the
main checkout. **It is not an operating-system or filesystem sandbox.** Claude
still runs with the owner's account permissions and can reach accessible
absolute paths outside the worktree. Use a container or virtual machine around
the complete workflow when true filesystem confinement is required.

The guarded runner adds the bypass flag only after validating the linked
worktree and task packet. Never run Claude with that flag manually, never put
credentials or secrets in a task packet, and review every candidate change
before Codex accepts it.

## Supported systems and accounts

| System | Required shell | Owner setup window |
| --- | --- | --- |
| Windows | Windows PowerShell 5.1 (`powershell`) | Visible Windows PowerShell window |
| macOS | PowerShell 7 (`pwsh`) | Visible macOS Terminal window |

Linux and other hosts are not supported by this runner.

Before installing, create or obtain:

- a GitHub account if you need to clone private repositories or push accepted
  work;
- an OpenAI account with access to Codex; and
- an Anthropic account with access to Claude Code.

The commands below use the official
[Codex installers](https://developers.openai.com/codex/cli/),
[Claude Code quickstart](https://code.claude.com/docs/en/quickstart),
[Homebrew installer](https://brew.sh/), and
[PowerShell for macOS instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/alternate-install-methods?view=powershell-7.6#install-on-macos-using-homebrew).

## Windows installation

Use a normal PowerShell window. Run each numbered step separately so you can
check the result before continuing.

### 1. Install Git

```powershell
winget install --id Git.Git -e
```

Close and reopen PowerShell after installation, then verify:

```powershell
git --version
```

Success prints a Git version such as `git version 2.x`.

### 2. Install and sign in to Codex

```powershell
irm https://chatgpt.com/codex/install.ps1 | iex
codex --version
codex login
codex login status
```

Complete the browser sign-in opened by `codex login`. Success is confirmed
when `codex --version` prints a version and `codex login status` reports an
authenticated session.

### 3. Install and sign in to Claude Code

```powershell
irm https://claude.ai/install.ps1 | iex
claude --version
claude
```

The first `claude` session guides you through browser authentication. Complete
the prompts, then exit the Claude session when it is ready. `claude --version`
must print a version before continuing.

### 4. Clone this repository

The following command places the public repository directly under your home
folder:

```powershell
$repo = Join-Path $HOME 'codex-claude-delegation-skill'
git clone https://github.com/admworx88/codex-claude-delegation-skill.git $repo
Set-Location $repo
```

If Git says the destination already exists, do not overwrite it. Use the
update procedure later in this README.

### 5. Install the complete skill folder

This first-install command deliberately stops if a copy is already installed:

```powershell
$skillsRoot = Join-Path $HOME '.agents\skills'
$source = Join-Path $repo 'delegating-to-claude-code'
$destination = Join-Path $skillsRoot 'delegating-to-claude-code'

New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
if (Test-Path -LiteralPath $destination) {
    throw "Skill already exists at $destination. Use the update procedure instead."
}
Copy-Item -Recurse -LiteralPath $source -Destination $destination
```

Verify the instructions, guarded runner, task-packet example, and result schema:

```powershell
Test-Path (Join-Path $destination 'SKILL.md')
Test-Path (Join-Path $destination 'scripts\Invoke-ClaudeDelegation.ps1')
Test-Path (Join-Path $destination 'references\task-packet.example.json')
Test-Path (Join-Path $destination 'references\result-schema.json')
```

Success prints `True` four times.

### 6. Restart Codex

Close every running Codex CLI session and start a new one after installation.
The new session discovers user skills from:

```text
~/.agents/skills/delegating-to-claude-code
```

## macOS installation

Open the Terminal application. The commands in this section are shell commands
unless a step explicitly says to type inside Codex.

### 1. Install Apple command-line tools and Git

```bash
xcode-select --install
```

Accept the macOS installer prompt. When it finishes, verify:

```bash
git --version
```

Success prints a Git version. If the command-line tools were already
installed, macOS may say so; the version check is the deciding signal.

### 2. Install Homebrew if needed

Check first:

```bash
brew --version
```

If that prints `command not found`, use the current command from the official
[Homebrew installation page](https://brew.sh/):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

At the end, Homebrew may print a `Next steps` command that adds Homebrew to
your shell environment. Run the command it prints, open a new Terminal window,
and verify:

```bash
brew --version
```

### 3. Install PowerShell 7

```bash
brew install powershell
pwsh --version
```

Success prints `PowerShell 7.x`. The macOS runner requires `pwsh`; it does not
fall back to Windows PowerShell.

### 4. Install and sign in to Codex

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
codex login
codex login status
```

Complete the browser sign-in opened by `codex login`. Success is confirmed
when `codex --version` prints a version and `codex login status` reports an
authenticated session.

### 5. Install and sign in to Claude Code

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude --version
claude
```

Complete the first-run browser authentication, then exit the Claude session
when it is ready. `claude --version` must print a version before continuing.

### 6. Clone this repository

```bash
repo="$HOME/codex-claude-delegation-skill"
git clone https://github.com/admworx88/codex-claude-delegation-skill.git "$repo"
cd "$repo"
```

If Git says the destination already exists, do not overwrite it. Use the
update procedure later in this README.

### 7. Install the complete skill folder

This first-install command stops if a copy is already installed:

```bash
skills_root="$HOME/.agents/skills"
source_dir="$repo/delegating-to-claude-code"
destination="$skills_root/delegating-to-claude-code"

mkdir -p "$skills_root"
if [ -e "$destination" ]; then
  echo "Skill already exists at $destination. Use the update procedure instead."
else
  cp -R "$source_dir" "$destination"
fi
```

Verify the instructions, guarded runner, task-packet example, and result schema:

```bash
test -f "$destination/SKILL.md" && echo "SKILL.md found"
test -f "$destination/scripts/Invoke-ClaudeDelegation.ps1" && echo "Runner found"
test -f "$destination/references/task-packet.example.json" \
  && echo "Task-packet example found"
test -f "$destination/references/result-schema.json" \
  && echo "Result schema found"
```

Success prints `SKILL.md found`, `Runner found`, `Task-packet example found`,
and `Result schema found`.

### 8. Restart Codex

Close every running Codex CLI session and start a new one. Codex discovers the
skill from:

```text
~/.agents/skills/delegating-to-claude-code
```

## First use

### 1. Open the project you want to change

On Windows, run in PowerShell:

```powershell
Set-Location 'C:\path\to\your-git-repository'
git status
codex
```

On macOS, run in Terminal:

```bash
cd "/path/to/your-git-repository"
git status
codex
```

Replace the example path with the real path. `git status` must recognize a Git
repository. The final command starts the interactive Codex prompt.

### 2. Invoke the skill inside Codex

The next block is **not a shell command**. Paste it into the interactive Codex
prompt that appeared after you ran `codex`:

```text
$delegating-to-claude-code

Fix the CSV export bug. Keep Codex as orchestrator. Let Codex choose the
delegation mode, independently verify Claude's work, and perform all Git
operations only after acceptance.
```

Using the `$delegating-to-claude-code` name explicitly asks Codex to load this
skill. Codex should then:

1. plan the bounded task;
2. create or select one named linked feature worktree;
3. add `.codex/claude-handoff/` to that worktree's `.gitignore`;
4. write a local task packet and ledger;
5. dry-run and execute the guarded Claude invocation;
6. receive a `needs-review` candidate result;
7. inspect the complete diff and independently rerun verification;
8. accept, request a bounded revision, or reject the candidate; and
9. perform commits, pushes, or integration only after acceptance and owner
   direction.

All top-level delegations for the same feature run sequentially in that one
linked worktree. Claude may use internal subagents or an experimental agent
team only when Codex determines the task structure supports it.

## Complete prompt examples

Paste one of these examples **inside an interactive Codex session**, not into
PowerShell or Terminal.

### Small, tightly coupled task: direct

```text
$delegating-to-claude-code

Fix the off-by-one error in the invoice CSV page count and add its focused
regression test. This is a small, tightly coupled change, so use direct mode
if preflight confirms it is appropriate. Keep Claude inside the explicitly
allowed source and test files. Codex must review the diff, rerun the test, and
own every Git operation.
```

### Medium task: Claude subagents

```text
$delegating-to-claude-code

Implement validation for the profile import flow. Ask Codex to consider
subagents because investigation, implementation, and focused test analysis can
be bounded independently inside one top-level Claude invocation. Keep one
linked feature worktree and one consolidated result. Codex must independently
review and verify all candidate changes before acceptance.
```

### Long independent workstreams: experimental agent team

```text
$delegating-to-claude-code

Complete the long provider-adapter migration. Ask Codex to consider the experimental
agent-team mode only if these workstreams are truly independent:

- Workstream A exclusively owns packages/github-adapter/**
- Workstream B exclusively owns packages/gitlab-adapter/**

Do not overlap owned paths or allow teammates to edit shared configuration.
Use one linked feature worktree and one top-level Claude invocation. Codex must
review the combined diff, rerun all required verification, and retain sole
ownership of commits, pushes, and integration.
```

Agent-team mode is experimental. Codex should choose direct or subagents when
work is dependent, ownership overlaps, or the task is not large enough to
justify a bounded team. Duration alone is not a reason to run work in parallel.

## What happens when installation or login is missing

The runner never performs silent installation or authentication.

If Claude is missing or unauthenticated, the runner first records
`waiting-for-owner`, opens a visible setup window, and stops the delegation:

- Windows opens a Windows PowerShell window. Follow its message to install
  Claude if needed or complete `claude auth login`.
- macOS opens Terminal. Install Claude if needed, then run `claude`, enter
  `/login` when instructed, and complete the browser flow.

No setup window receives `--dangerously-skip-permissions`. Close the setup
window after authentication, return to Codex, and ask it to rerun the same
guarded packet. The owner always performs account authentication manually.

## Update the skill

These procedures make a timestamped backup before replacing the installed
copy. Finish any active delegation first, then close Codex.

### Windows update

Run in PowerShell:

```powershell
& {
    $ErrorActionPreference = 'Stop'

    function Test-RequiredSkillFiles([string]$Root) {
        $required = @(
            'SKILL.md'
            'scripts\Invoke-ClaudeDelegation.ps1'
            'references\task-packet.example.json'
            'references\result-schema.json'
        )
        return -not ($required | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
        })
    }

    $repo = Join-Path $HOME 'codex-claude-delegation-skill'
    $source = Join-Path $repo 'delegating-to-claude-code'
    $skillsRoot = Join-Path $HOME '.agents\skills'
    $destination = Join-Path $skillsRoot 'delegating-to-claude-code'
    $backupRoot = Join-Path $HOME '.agents\skill-backups'
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stage = Join-Path $skillsRoot ".delegating-to-claude-code-stage-$stamp"
    $backup = Join-Path $backupRoot "delegating-to-claude-code-$stamp"
    $failed = Join-Path $skillsRoot ".delegating-to-claude-code-failed-$stamp"

    if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
        throw "Repository not found at $repo"
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw "Installed skill not found at $destination"
    }
    if (-not (Test-RequiredSkillFiles $destination)) {
        throw "Installed skill is incomplete at $destination"
    }

    try {
        Set-Location -LiteralPath $repo -ErrorAction Stop
    }
    catch {
        throw "Cannot enter repository: $repo"
    }
    git rev-parse --is-inside-work-tree
    if ($LASTEXITCODE -ne 0) {
        throw "Not a Git worktree: $repo"
    }
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        throw 'git pull --ff-only failed; the installed skill was not changed.'
    }

    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Updated skill source not found at $source"
    }
    if (-not (Test-RequiredSkillFiles $source)) {
        throw "Updated skill source is incomplete at $source"
    }
    if ((Test-Path -LiteralPath $stage) -or
        (Test-Path -LiteralPath $backup) -or
        (Test-Path -LiteralPath $failed)) {
        throw 'Unique update staging or backup path already exists.'
    }

    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Copy-Item -Recurse -LiteralPath $source -Destination $stage
    if (-not (Test-RequiredSkillFiles $stage)) {
        throw "Staged skill verification failed. Live install is unchanged. Inspect $stage"
    }

    Move-Item -LiteralPath $destination -Destination $backup
    try {
        Move-Item -LiteralPath $stage -Destination $destination
        if (-not (Test-RequiredSkillFiles $destination)) {
            throw 'Final installed-skill verification failed.'
        }
    }
    catch {
        $updateError = $_.Exception.Message
        $preservedCandidate = $stage
        try {
            if (Test-Path -LiteralPath $destination) {
                Move-Item -LiteralPath $destination -Destination $failed
                $preservedCandidate = $failed
            }
            Move-Item -LiteralPath $backup -Destination $destination
        }
        catch {
            throw "Update failed and automatic restore failed. Original backup: $backup. Staging or failed copy: $stage $failed"
        }
        throw "Update failed; the original skill was restored. Cause: $updateError. Preserved candidate: $preservedCandidate"
    }

    Write-Host "Skill updated. Previous installation: $backup"
}
```

Success prints `Skill updated` and the exact backup path. A pull, copy, or
staged-file verification failure leaves the live installation unchanged. A
final replacement failure restores the timestamped backup and reports any
preserved failed candidate. Restart Codex only after the success message.

### macOS update

Run in Terminal:

```bash
(
  set -euo pipefail

  required_files=(
    "SKILL.md"
    "scripts/Invoke-ClaudeDelegation.ps1"
    "references/task-packet.example.json"
    "references/result-schema.json"
  )
  verify_skill() {
    local root="$1"
    local relative
    for relative in "${required_files[@]}"; do
      [ -f "$root/$relative" ] || return 1
    done
  }

  repo="$HOME/codex-claude-delegation-skill"
  source_dir="$repo/delegating-to-claude-code"
  skills_root="$HOME/.agents/skills"
  destination="$skills_root/delegating-to-claude-code"
  backup_root="$HOME/.agents/skill-backups"
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  stage="$skills_root/.delegating-to-claude-code-stage-$stamp"
  backup="$backup_root/delegating-to-claude-code-$stamp"
  failed="$skills_root/.delegating-to-claude-code-failed-$stamp"

  [ -d "$repo" ] || {
    echo "Repository not found at $repo" >&2
    exit 1
  }
  [ -d "$destination" ] || {
    echo "Installed skill not found at $destination" >&2
    exit 1
  }
  verify_skill "$destination" || {
    echo "Installed skill is incomplete at $destination" >&2
    exit 1
  }

  cd "$repo" || {
    echo "Cannot enter repository: $repo" >&2
    exit 1
  }
  git rev-parse --is-inside-work-tree >/dev/null || {
    echo "Not a Git worktree: $repo" >&2
    exit 1
  }
  git pull --ff-only || {
    echo "git pull --ff-only failed; the installed skill was not changed." >&2
    exit 1
  }

  [ -d "$source_dir" ] || {
    echo "Updated skill source not found at $source_dir" >&2
    exit 1
  }
  verify_skill "$source_dir" || {
    echo "Updated skill source is incomplete at $source_dir" >&2
    exit 1
  }
  [ ! -e "$stage" ] && [ ! -e "$backup" ] && [ ! -e "$failed" ] || {
    echo "Unique update staging or backup path already exists." >&2
    exit 1
  }

  mkdir -p "$backup_root"
  cp -R "$source_dir" "$stage"
  verify_skill "$stage" || {
    echo "Staged skill verification failed. Live install is unchanged. Inspect $stage" >&2
    exit 1
  }

  mv "$destination" "$backup"
  if ! mv "$stage" "$destination" || ! verify_skill "$destination"; then
    update_error="final move or installed-skill verification failed"
    preserved_candidate="$stage"
    if [ -e "$destination" ]; then
      mv "$destination" "$failed" || {
        echo "Update and automatic restore failed. Original backup: $backup" >&2
        exit 1
      }
      preserved_candidate="$failed"
    fi
    mv "$backup" "$destination" || {
      echo "Update and automatic restore failed. Original backup: $backup" >&2
      exit 1
    }
    echo "Update failed; the original skill was restored. Cause: $update_error. Preserved candidate: $preserved_candidate" >&2
    exit 1
  fi

  echo "Skill updated. Previous installation: $backup"
)
```

Success prints `Skill updated` and the exact backup path. A pull, copy, or
staged-file verification failure leaves the live installation unchanged. A
final replacement failure restores the timestamped backup and reports any
preserved failed candidate. Restart Codex only after the success message.

## Uninstall the skill

Finish any active delegation and close Codex first. The following commands
uninstall only the exact `delegating-to-claude-code` directory by moving it to
a recoverable timestamped backup. They do not remove `.agents`, other skills,
your repositories, or your home directory.

### Windows uninstall

```powershell
$destination = Join-Path $HOME '.agents\skills\delegating-to-claude-code'
$backupRoot = Join-Path $HOME '.agents\skill-backups'
$removed = Join-Path $backupRoot ("delegating-to-claude-code-uninstalled-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

if (-not (Test-Path -LiteralPath $destination)) {
    throw "Installed skill not found at $destination"
}
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
Move-Item -LiteralPath $destination -Destination $removed
Write-Host "Uninstalled. Recoverable copy: $removed"
```

### macOS uninstall

```bash
destination="$HOME/.agents/skills/delegating-to-claude-code"
backup_root="$HOME/.agents/skill-backups"
removed="$backup_root/delegating-to-claude-code-uninstalled-$(date +%Y%m%d-%H%M%S)"

if [ ! -d "$destination" ]; then
  echo "Installed skill not found at $destination"
else
  mkdir -p "$backup_root"
  mv "$destination" "$removed"
  echo "Uninstalled. Recoverable copy: $removed"
fi
```

Restart Codex. To restore a backup, move that exact backup directory back to
`~/.agents/skills/delegating-to-claude-code` while Codex is closed.

## Troubleshooting

### A command is not found

Open a new PowerShell or Terminal window first; installers often update PATH
for new sessions.

On Windows:

```powershell
Get-Command git
Get-Command powershell
Get-Command codex
Get-Command claude
```

Each command should print an application path. Re-run only the official
installer for the missing command. If `winget` itself is missing, install Git
from [git-scm.com](https://git-scm.com/download/win).

On macOS:

```bash
command -v git
command -v brew
command -v pwsh
command -v codex
command -v claude
```

Each command should print a path. If `brew` is missing after installation, run
the `Next steps` shell-environment command printed by Homebrew. If `pwsh` is
missing, run `brew install powershell`. For Codex or Claude, rerun the official
installer and follow any PATH instruction it prints.

### Codex login fails or expires

```text
codex login
codex login status
```

Run those commands in PowerShell or Terminal, not inside the Codex prompt.
Complete the browser flow with the intended OpenAI account.

### Claude login fails or expires

Run `claude` in PowerShell or Terminal, then type `/login` inside the Claude
session and complete the browser flow. On Windows, `claude auth login` is also
the recovery command shown by the runner's visible setup window. Verify
afterward with:

```text
claude --version
```

Return to Codex and retry the same delegation only after authentication is
complete.

### Codex cannot discover the skill

Close and restart Codex, then check for the correct non-nested location.

Windows:

```powershell
$destination = Join-Path $HOME '.agents\skills\delegating-to-claude-code'
Test-Path (Join-Path $destination 'SKILL.md')
Test-Path (Join-Path $destination 'delegating-to-claude-code\SKILL.md')
```

The first result must be `True`; the second should be `False`.

macOS:

```bash
destination="$HOME/.agents/skills/delegating-to-claude-code"
test -f "$destination/SKILL.md" && echo "Correct skill location"
test ! -f "$destination/delegating-to-claude-code/SKILL.md" \
  && echo "No nested duplicate"
```

Both success messages should print. If the nested file exists, back up the
installed directory and reinstall from the repository using the exact
destination shown above.

### `pwsh` is missing on macOS

```bash
brew install powershell
pwsh --version
```

The second command must print `PowerShell 7.x`. Do not substitute `powershell`
or another shell for the guarded runner.

### macOS does not open the owner setup Terminal

Verify the built-in `open` command and Terminal application:

```bash
command -v open
open -a Terminal
```

The first command should print `/usr/bin/open`; the second should open
Terminal. The runner stores generated `.command` files only under the ignored
`.codex/claude-handoff/` directory and secures them to mode `700`. If macOS
reports a permission problem, inspect the exact generated file and repair only
that file:

```bash
ls -l "<linked-worktree>/.codex/claude-handoff/"*.command
chmod 700 "/absolute/path/to/generated-owner-setup.command"
```

Then return to Codex and retry. Do not apply recursive permission changes to
the repository or home directory.

### The runner rejects the checkout or worktree

The runner intentionally refuses the main checkout, nested paths, mismatched
branches, and unexpected Git state. Diagnose without deleting anything:

```text
git rev-parse --show-toplevel
git branch --show-current
git worktree list --porcelain
git status
```

Ask Codex to create or select one named linked feature worktree and use its
exact canonical root. Keep all top-level tasks for that feature sequential in
the same worktree. Do not bypass the guard or move the task into the main
checkout.

### A delegation is rejected

Rejection is a safety result, not a request to reset the repository. Preserve
the linked worktree and `.codex/claude-handoff/` evidence. Ask Codex to inspect
the ledger, normalized result, raw log, Git snapshots, and complete diff.
Codex may prepare a new bounded revision packet for safe incomplete work.
Destructive cleanup such as reset, clean, or worktree removal requires explicit
owner approval.

### Local tests or GitHub Actions fail

From this repository root, run the test for the current host.

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Invoke-ClaudeDelegation.Tests.ps1
```

macOS:

```bash
pwsh -NoProfile -File ./tests/Invoke-ClaudeDelegation.Mac.Tests.ps1
```

Success exits with code `0`. The tests use a deterministic fake Claude command
and do not need live Claude credentials. GitHub Actions runs the Windows and
macOS suites on their native hosted runners; inspect the failed job and step
before changing the runner. Native macOS support should not be claimed from a
Windows-only test result.

## How the local ledger works

Each feature keeps durable handoff state under:

```text
.codex/claude-handoff/
```

The folder contains task packets, `ledger.json`, the single-task lock, raw
output, normalized results, Git-state evidence, and Codex review decisions.
It stays local and ignored by Git. The ledger preserves task status and
evidence across separate Claude sessions; it does not contain or transfer the
Codex conversation automatically, so the task packet must include the bounded
context Claude needs. Never store credentials, reusable tokens, or secrets in
the ledger.

## Trust boundary summary

- Codex plans, defines scope, creates the task packet, reviews, verifies,
  accepts or rejects, and owns every Git operation.
- Claude may edit only task-packet `allowedPaths` and returns untrusted
  candidate evidence.
- The runner rejects writes to forbidden paths, out-of-scope writes, Git-state
  changes, ignore-rule changes, sibling-worktree changes, and unsafe packet or
  host conditions. Detection is based on before/after file and Git-state
  snapshots, so it observes what Claude *wrote*, not what it read.
- Build and cache output that Git ignores is recorded as `ignoredArtifacts` for
  review rather than rejected, so a required verification command does not fail
  its own delegation. Anything matching `forbiddenPaths`, any tracked file, and
  any change to a `.gitignore` or exclude file still rejects.
- Claude is denied Git tool access and any commit, push, pull, merge, rebase,
  reset, checkout, branch switch, stash, tag, remote edit, or worktree creation
  is detected by the before/after snapshots. Denial is enforced by Claude Code
  permission rules over Bash and PowerShell commands; work that reaches Git
  indirectly, such as through a shell script, is caught by detection rather
  than prevented.
- No automatic commit or push occurs after Claude finishes. Codex acts only
  after independent review, acceptance, and owner direction.

## License

[MIT](LICENSE) (c) 2026 Aljon Moliva
