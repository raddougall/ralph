# Jarvis Agent Instructions

## Overview

Jarvis is an autonomous AI agent loop that runs Amp (default) or Codex repeatedly until all PRD items are complete. Each iteration is a fresh agent instance with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Jarvis (from your project that has prd.json)
./jarvis.sh [max_iterations]

# Legacy compatibility command
./ralph.sh [max_iterations]
```

## Key Files

- `jarvis.sh` - The primary bash loop that spawns fresh Amp/Codex instances
- `ralph.sh` - Backward-compatibility shim that forwards to `jarvis.sh`
- `prompt.md` - Instructions given to each Amp instance
- `prd.json.example` - Example PRD format
- `flowchart/` - Interactive React Flow diagram explaining how Jarvis works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh agent instance with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Codex unattended default is top-level `--sandbox workspace-write -a never` plus exec flags `--color never`; this avoids interactive approval pauses during long runs.
- When Jarvis uses project-local `CODEX_HOME`, it mirrors `~/.codex/auth.json` into the project home so Codex remains authenticated without using global session storage.
- For Codex runs, detect completion from `--output-last-message` content, not streamed logs, to avoid false `<promise>COMPLETE</promise>` matches.
- Before each iteration, run git preflight checks that verify `.git` writeability and fail before story edits with explicit recovery guidance; temp branch probes are only needed when branch policy uses PRD branch switching.
- Treat repeated Codex stream disconnect/reconnect loops (for example `codex/responses` transport interruptions) as retryable infrastructure failures, not story failures.
- Use `JARVIS_BRANCH_POLICY` to control branching strategy per run (`prd`, `main`, `current`) so early-system work can go direct to main without per-story branch creation.
- Default commit scope is durable story artifacts; local scratch/session notes (especially `.gitignore`d files) should remain uncommitted unless explicitly requested as long-term docs.
- Jarvis pins each iteration to the selected story ID, logs story id/title/priority before launch, and audits non-target `prd.json` story mutations with end-of-run summary output for manual review.
- Pinned-story mutation handling is configurable via `JARVIS_PINNED_SCOPE_MUTATION_POLICY` (`rollback` default, `audit`, or `fail`); rollback restores non-target PRD stories automatically.
- Codex runs support effective capability probing (`JARVIS_CODEX_CAPABILITY_PREFLIGHT`) and optional strict fail-fast mode (`JARVIS_CODEX_CAPABILITY_PREFLIGHT_STRICT`) for nested git/network mismatches.
- Codex iterations are timeout-bounded by default (`JARVIS_CODEX_ITERATION_TIMEOUT_SECONDS`, default `1800`) when `timeout`/`gtimeout` is available, so long context-walk stalls cannot run indefinitely.
- Network preflight for Codex also validates npm registry reachability by default (`registry.npmjs.org`) to catch package-install blockers before story execution.
- If nested runs cannot resolve ClickUp DNS, Jarvis disables ClickUp actions for the rest of the run instead of repeatedly retrying wrapper/env diagnostics.
- Default commit flow is runner-owned (`JARVIS_COMMIT_MODE=runner`) so Jarvis parent creates the story commit; `agent` mode remains available for direct child commits.
- Runner commit mode supports strict isolation guard (`JARVIS_RUNNER_COMMIT_REQUIRE_CLEAN_START=1`) to prevent story mixing when worktree is already dirty.
- Story scheduling should treat planning markers as non-executable (`planning: true`, `skip: true`, or `clickupStatus: "planning"`), and ClickUp sync should honor per-story `clickupStatus` before `passes` mapping.
- Host package manager commands are guarded through `guard-bin/`; leave `JARVIS_ALLOW_SYSTEM_CHANGES=0` (legacy `RALPH_ALLOW_SYSTEM_CHANGES`) unless the user explicitly approves system changes.
- Projects synced with the launcher include a `scripts/jarvis/house-party-protocol.sh` preset for Codex full-access runs (`danger-full-access`, network enabled, `-a never`).
- Run Jarvis with `JARVIS_PROJECT_DIR` (legacy `RALPH_PROJECT_DIR`) or from project cwd so `prd.json`, `progress.txt`, archives, and logs stay project-local.
- Project iterations must run with writable access inside `JARVIS_PROJECT_DIR`; read-only intent applies to paths outside the active project root, not the project itself.
- Jarvis auto-syncs project-local wrappers/docs/templates from master at run start by default (`JARVIS_PROJECT_SYNC_ON_START=1`), and this sync must not overwrite existing project secret values.
- Project runs may read shared Jarvis runtime files but must not edit Jarvis itself or other files outside the active project root unless explicitly requested.
- Localhost test interactions are fine without per-click approval prompts, but any server started for testing must be shut down before the iteration ends.
- Every project must maximize automated testing for changed behavior and keep CI-ready, non-interactive test scripts/commands up to date.
- Always update AGENTS.md with discovered patterns for future iterations
- If ClickUp credentials are configured and `scripts/clickup/sync_clickup_to_prd.sh` exists, Jarvis pre-syncs ClickUp `[US-xxx]` tasks into local `prd.json` at run start (default enabled).
- Optionally sync a human-readable directives reference doc in ClickUp at run start via `JARVIS_CLICKUP_DIRECTIVES_SYNC_ON_START=1` using `scripts/clickup/sync_jarvis_directives_to_clickup.sh`.
- Directives doc sync should target project-specific ClickUp Doc URLs and follow clean-state policy: sync on `main` commits, skip feature branches until merged.
- Runtime failures from project runs should be auto-captured into Jarvis feedback logs so core fixes can be prioritized without manual copy/paste incident reporting.
- If ClickUp credentials are configured, every story must use `to do` as the ready queue (`backlog` is ideas only), move status `in progress` -> `testing`, and post live task comments at `start`, `progress`, and `testing` phases with a `Jarvis/Codex` label; include commit linkage plus activity notes (implementation details, test commands/outcomes, test file paths, smoke result), keep ClickUp note content consistent with terminal summaries, link related tasks for traceability, and use ClickUp task type `bug` for bug work linked back to the originating story.
- Branch-based policy: non-main completions should remain `testing` for manual verification; automatic `deployed` transitions are optional and main-only (`JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN=1`).
- Default main-branch completion should stop at `done` during local/dev phases (not `deployed`) unless explicitly opted into auto-deploy transitions.
- Approval-gated commands should be queued in `approval-queue.txt`, blocked stories marked with `BLOCKED:` in `prd.json` notes, and iterations should continue with remaining unblocked stories.
