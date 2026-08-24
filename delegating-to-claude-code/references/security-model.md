# Delegation security model

Read this reference before changing runner guard behavior, reviewing its
security assumptions, or deciding whether unusual ignored artifacts or
repository violations are safe.

## Prevention and detection

The runner denies Claude Git access in layers: task and prompt prohibitions,
Bash and native PowerShell tool denial, and before/after snapshots. It
fingerprints files, sibling worktrees, the index, refs, repository and worktree
configuration, exclude files, hooks, HEAD, branch, remotes, and status. A
forbidden-path, out-of-scope, Git-state, hook, sibling-worktree, or probe
violation makes the decision `rejected`.

`forbiddenPaths` becomes enforced `Read` and `Edit` deny rules because a read
leaves no trace in a snapshot. Each pattern is emitted both bare, for gitignore
depth semantics, and worktree-absolute, for documented rooted anchoring. The
runner also adds absolute deny rules for credential locations outside the
worktree, edit-denies both Git directories and the user Git configuration
directory, and uses `--strict-mcp-config` with `--setting-sources user` so the
delegated repository cannot register hooks or MCP servers.

These deny rules are defense in depth, not a sandbox. Claude Code applies them
to built-in tools and recognized shell file commands. They do not prevent an
arbitrary subprocess from opening a file itself. Use a container or VM when a
read of an accessible host path must be impossible.

## Deliberate limitations

- The `//**/.env.*` deny also blocks `.env.example` and similar templates.
  Deny rules cannot express an exception safely. Put any required template
  contents in the packet `context` instead of relaxing the rule.
- A `.gitignore` edit always records `ignore-rules-changed` and rejects, even
  when `.gitignore` appears in `allowedPaths`. Codex must make ignore-rule
  changes outside delegation.

## Ignored verification artifacts

Verification commands may create ignored build or cache output outside
`allowedPaths`. Such a path is recorded as `ignoredArtifacts`, not a scope
violation, only when it is outside `allowedPaths`, does not match
`forbiddenPaths`, and Git reports it ignored.

This classification does not soften the sensitive boundaries:

- a `forbiddenPaths` match is always a violation regardless of ignore rules;
- Git never reports a tracked file as ignored, so tracked out-of-scope edits
  still reject;
- any `.gitignore` or exclude-file change records `ignore-rules-changed` and
  rejects; and
- exclude fingerprints cover both `info/exclude` files,
  `core.excludesFile`, and the default user excludes file.

Review every `ignoredArtifacts` entry. The runner classifies it as
non-rejecting evidence, not as automatically clean.
