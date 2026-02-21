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
- Host package manager commands are guarded through `guard-bin/`; leave `JARVIS_ALLOW_SYSTEM_CHANGES=0` (legacy `RALPH_ALLOW_SYSTEM_CHANGES`) unless the user explicitly approves system changes.
- Run Jarvis with `JARVIS_PROJECT_DIR` (legacy `RALPH_PROJECT_DIR`) or from project cwd so `prd.json`, `progress.txt`, archives, and logs stay project-local.
- Project runs may read shared Jarvis runtime files but must not edit Jarvis itself or other files outside the active project root unless explicitly requested.
- Localhost test interactions are fine without per-click approval prompts, but any server started for testing must be shut down before the iteration ends.
- Every project must maximize automated testing for changed behavior and keep CI-ready, non-interactive test scripts/commands up to date.
- Always update AGENTS.md with discovered patterns for future iterations
- If ClickUp credentials are configured and `scripts/clickup/sync_clickup_to_prd.sh` exists, Jarvis pre-syncs ClickUp `[US-xxx]` tasks into local `prd.json` at run start (default enabled).
- If ClickUp credentials are configured, every story must use `to do` as the ready queue (`backlog` is ideas only), move status `in progress` -> `testing`, include commit linkage, and include an activity note with implementation details, test commands/outcomes, and test file paths; link related tasks for traceability, and use ClickUp task type `bug` for bug work linked back to the originating story.
- Approval-gated commands should be queued in `approval-queue.txt`, blocked stories marked with `BLOCKED:` in `prd.json` notes, and iterations should continue with remaining unblocked stories.
