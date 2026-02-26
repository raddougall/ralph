# Jarvis Directives Overview

This document summarizes the runtime directives Jarvis follows during autonomous iteration runs.

## Core Operating Model

- Jarvis runs iterative agent sessions until stories are complete or max iterations are reached.
- Each iteration should complete at most one story.
- State is persisted through `prd.json`, `progress.txt`, and git history.

## Story Selection and Completion

- Pick the highest-priority unblocked story where `passes: false`.
- Keep blocked stories marked with `BLOCKED:` notes and continue with remaining unblocked work.
- Mark a story as passing only after implementation and automated checks succeed.

## Branch and Git Policy

- Branch handling is controlled by `JARVIS_BRANCH_POLICY`:
- `prd`: use PRD `branchName` (legacy/default branch behavior).
- `main`: work directly on `JARVIS_MAIN_BRANCH`.
- `current`: stay on the current branch.
- Git preflight checks run before story work to verify `.git` writeability; failures abort before edits.

## Commit Scope

- Commit durable story artifacts and project changes needed long term.
- Do not force-add local scratch/session notes by default (especially `.gitignore`d files).
- Keep unrelated local changes intact; do not revert user work.

## ClickUp Workflow

- When configured, ClickUp updates are required for each story.
- Use `to do` as the active queue, move to `in progress` at start, then `testing` when ready.
- Post activity comments at `start`, `progress`, and `testing` using `Jarvis/Codex` labeling.
- Include implementation notes, exact test commands/outcomes, and changed test file paths.

## Infrastructure and Reliability Guardrails

- Treat repeated Codex stream disconnect loops as retryable infrastructure failures.
- Run nested Codex capability preflight (`JARVIS_CODEX_CAPABILITY_PREFLIGHT`) to probe effective git write + network/DNS access before story work.
- Bound Codex iteration runtime with `JARVIS_CODEX_ITERATION_TIMEOUT_SECONDS` (default `1800` when timeout tooling exists) to prevent context-walk stalls.
- Keep project edits scoped to `JARVIS_PROJECT_DIR`.
- Avoid host system package-manager changes unless explicitly approved.
- Queue approval-gated commands in `approval-queue.txt` and keep iterating unblocked work.

## Runtime Access and Sandbox Modes

- Default unattended Codex mode is workspace-write with no interactive approvals:
- `JARVIS_CODEX_GLOBAL_FLAGS="--sandbox workspace-write -a never"`
- Default Codex exec flags:
- `JARVIS_CODEX_FLAGS="--color never"`
- If `JARVIS_CODEX_ENABLE_NETWORK=1` and workspace-write sandbox is used, Jarvis enables workspace network access for Codex runs.
- `danger-full-access` is optional and should be used only when explicitly intended for broader host/system access.
- For full-access runs, project wrappers provide `scripts/jarvis/house-party-protocol.sh` (Codex + network + `danger-full-access` + unattended approvals).
- For project runs, writable access inside `JARVIS_PROJECT_DIR` is required for normal behavior (`git`, edits, tests, artifacts).
- Read-only behavior is intended for paths outside the active project root, not for the project itself.
- If nested Codex cannot resolve ClickUp DNS, Jarvis disables ClickUp actions for the remainder of that run to avoid repeated diagnostic loops.

## Branch-Aware Protocol Doc Sync

- Jarvis can sync this directives overview to a project-specific ClickUp Doc.
- Doc target is configured per project in `scripts/clickup/.env.clickup` via `CLICKUP_DIRECTIVES_DOC_URL`.
- Recommended clean-state policy is `JARVIS_CLICKUP_DIRECTIVES_SYNC_BRANCH_POLICY=main_only`:
- sync on `main` commits (and run start on main), skip feature branches until merge.

## Testing and Quality

- Run CI-ready automated checks for changed behavior before committing.
- For UI changes, include browser verification plus automated UI coverage where feasible.
- Keep changes focused and aligned with existing project conventions.

## Documentation and Learning Loop

- Append iteration summaries and learnings to `progress.txt`.
- Promote reusable patterns into `AGENTS.md` for future iterations.
- Keep this overview human-readable and aligned with current Jarvis directives.
