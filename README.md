# Jarvis

![Jarvis](ralph.webp)

Jarvis is an autonomous AI agent loop that runs [Amp](https://ampcode.com) (default) or Codex repeatedly until all PRD items are complete. Each iteration is a fresh agent instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph/Jarvis](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- [Amp CLI](https://ampcode.com) installed and authenticated (default), or Codex CLI
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Use master Jarvis from each project (recommended)

Create a tiny project-local launcher (example path: `scripts/jarvis/jarvis.sh`) that calls this repo's `jarvis.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JARVIS_HOME="${JARVIS_HOME:-$HOME/CodeDev/Jarvis}"
export JARVIS_PROJECT_DIR="$PROJECT_ROOT"
exec "$JARVIS_HOME/jarvis.sh" "$@"
```

This avoids duplicating Jarvis code into every project while keeping all writes in the project folder.

You can generate this launcher automatically from the target project root:

```bash
~/CodeDev/Jarvis/scripts/install-project-launcher.sh .
```

This installer also creates project-local ClickUp wrappers under `scripts/clickup/` that point to shared scripts in this Jarvis repo.

### Option 2: Copy to your project

Copy the Jarvis files into your project:

```bash
# From your project root
mkdir -p scripts/jarvis
cp /path/to/jarvis/jarvis.sh scripts/jarvis/
cp /path/to/jarvis/prompt.md scripts/jarvis/
chmod +x scripts/jarvis/jarvis.sh
```

### Option 3: Install skills globally (Amp only)

Copy the skills to your Amp config for use across all projects:

```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

### Option 4: Install skills for Codex

Codex only loads skills from `$CODEX_HOME/skills` (default: `~/.codex/skills`).
Symlink this repo’s skills into Codex:

```bash
./scripts/install-codex-skills.sh
```

Then restart Codex to pick up the new skills. Re-run the script any time you add or rename skills in this repo.

### Option 5: Use as Claude Code Marketplace

Add the Jarvis marketplace to Claude Code:

```bash
/plugin marketplace add raddougall/jarvis
```

Then install the skills:

```bash
/plugin install jarvis-skills@jarvis-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format (legacy skill name)

### Configure Amp auto-handoff (recommended, Amp only)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Jarvis to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Jarvis format

Use the Jarvis skill (legacy skill name: `ralph`) to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.
If you're using Codex, you can generate the PRD manually or with your preferred tooling.

### 3. Run Jarvis

```bash
# Amp (default)
./scripts/jarvis/jarvis.sh [max_iterations]

# Codex
JARVIS_AGENT=codex ./scripts/jarvis/jarvis.sh [max_iterations]

# Codex "House Party Protocol" (full-access preset)
./scripts/jarvis/house-party-protocol.sh [max_iterations]
```

Legacy compatibility command still works:

```bash
RALPH_AGENT=codex ./scripts/ralph/ralph.sh [max_iterations]
```

Default is 10 iterations.

## API Key And Secrets (Local Only)

Do not paste API keys in chat or commit them to git.

Recommended setup in each project:

```bash
cp scripts/jarvis/.env.jarvis.example scripts/jarvis/.env.jarvis.local
```

`scripts/install-project-launcher.sh` now creates `scripts/jarvis/.env.jarvis.local` automatically if missing.

Then set your key in `scripts/jarvis/.env.jarvis.local`:

```bash
OPENAI_API_KEY=...
```

The project launcher `scripts/jarvis/jarvis.sh` auto-loads this local file before invoking the shared Jarvis runtime.

Jarvis syncs `~/.codex/auth.json` and `~/.codex/config.toml` into active `CODEX_HOME` so authenticated/trusted Codex runs still work with project-scoped session storage.
Jarvis also auto-syncs project-local wrappers/docs/templates from master on run start (additive updates; existing secret values are preserved).

To customize Codex flags, set:
- `JARVIS_CODEX_GLOBAL_FLAGS` (default: `--sandbox workspace-write -a never`)
- `JARVIS_CODEX_FLAGS` (default: `--color never`)

Example:
```bash
JARVIS_CODEX_GLOBAL_FLAGS="--sandbox workspace-write -a never" \
JARVIS_CODEX_FLAGS="--color never -m o3" \
JARVIS_AGENT=codex ./scripts/jarvis/jarvis.sh
```

Project scoping controls:

- `JARVIS_PROJECT_DIR` (default: current working directory)
- `JARVIS_PROMPT_FILE` (optional explicit prompt path)
- `JARVIS_PROJECT_SYNC_ON_START` (default: `1`, auto-runs `scripts/install-project-launcher.sh` against the active project before iterations)
- `JARVIS_PROJECT_SYNC_STRICT` (default: `0`, set `1` to fail fast if project sync fails)
- `JARVIS_NETWORK_PREFLIGHT` (default: `1`, verify external endpoint reachability before iterations)
- `JARVIS_NETWORK_PREFLIGHT_STRICT` (default: `1`, fail fast when preflight fails; set `0` to continue with warning)
- `JARVIS_NETWORK_PREFLIGHT_TIMEOUT_SECONDS` (default: `8`, per-host timeout)
- `JARVIS_OPENAI_PREFLIGHT_URL` (default: `https://chatgpt.com`, endpoint used to validate OpenAI reachability for Codex runs)
- `JARVIS_NETWORK_PREFLIGHT_HOSTS` (optional comma-separated extra hosts to validate)
- `JARVIS_NETWORK_PREFLIGHT_NPM_REGISTRY` (default: `1`, include `registry.npmjs.org` in Codex network preflight checks)
- `JARVIS_BRANCH_POLICY` (default: `prd`; `main` = work directly on `JARVIS_MAIN_BRANCH`, `current` = stay on current branch, `prd` = use PRD `branchName`)
- `JARVIS_MAIN_BRANCH` (default: `main`; used by `JARVIS_BRANCH_POLICY=main` and as PRD branch creation base)
- `JARVIS_CODEX_SANDBOX_EXPECTED` (optional: `workspace-write` or `danger-full-access`; when set, Jarvis fails fast if effective `JARVIS_CODEX_GLOBAL_FLAGS` sandbox does not match)
- `JARVIS_CODEX_CAPABILITY_PREFLIGHT` (default: `1`, runs a nested Codex git/network capability probe before iterations)
- `JARVIS_CODEX_CAPABILITY_PREFLIGHT_STRICT` (default: `0`; set `1` to fail-fast when nested capability probe fails)
- `JARVIS_CODEX_CAPABILITY_PREFLIGHT_TIMEOUT_SECONDS` (default: `180`, timeout for nested capability probe command)
- `JARVIS_CODEX_ITERATION_TIMEOUT_SECONDS` (default: `1800`, timeout for each Codex iteration when `timeout`/`gtimeout` is available)
- `JARVIS_PINNED_SCOPE_MUTATION_POLICY` (default: `rollback`; options: `rollback`, `audit`, `fail` for non-target `prd.json` story mutations)
- `JARVIS_COMMIT_MODE` (default: `runner`; `runner` = parent Jarvis creates commits, `agent` = child agent commits)
- `JARVIS_RUNNER_COMMIT_REQUIRE_CLEAN_START` (default: `1`; fail-fast in runner mode when iteration starts dirty to avoid cross-story commit mixing)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_ON_START` (default: `0`; when enabled, updates a ClickUp Doc with a human-readable Jarvis directives overview at run start)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_STRICT` (default: `0`; set `1` to fail-fast if directives sync fails)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_BRANCH_POLICY` (default: `main_only`; keep docs clean by syncing only on `JARVIS_MAIN_BRANCH`)
- If `JARVIS_PROMPT_FILE` is unset and `<project>/.jarvis/prompt.md` exists, Jarvis uses that project-local prompt override. Legacy `.ralph/prompt.md` is still supported.

Manual project sync command:

```bash
./scripts/jarvis/sync-with-master.sh
```

Safety defaults:

- Host system package-manager mutations stay blocked unless explicitly approved and `JARVIS_ALLOW_SYSTEM_CHANGES=1` is set.
- Project runs are expected to write inside the active project root (`JARVIS_PROJECT_DIR`) for normal story work (code changes, tests, git commits, ClickUp updates).
- Read-only behavior is intended for paths outside `JARVIS_PROJECT_DIR`, not for the project root itself.
- Localhost smoke testing is allowed, but any temporary local servers must be stopped before the run completes.
- If nested Codex DNS cannot resolve ClickUp, Jarvis disables ClickUp actions for the remainder of that run instead of repeatedly retrying.
- In `JARVIS_COMMIT_MODE=runner`, Jarvis enforces commit gating for passed stories and stops if it cannot produce a clean committed state.

Jarvis will:
1. Apply branch policy:
   - `prd` (default): use/create PRD `branchName` from `JARVIS_MAIN_BRANCH`
   - `main`: work directly on `JARVIS_MAIN_BRANCH`
   - `current`: stay on current branch without switching/creating
2. Pick the highest priority executable unblocked story where `passes: false`, `notes` does not start with `BLOCKED:`, and the story is not planning/skip (`planning: true`, `skip: true`, or `clickupStatus: "planning"`).
3. If ClickUp is configured, move the matching `[US-xxx]` task from `to do` to `in progress` and post a kickoff plan comment
4. Implement that single story
5. Run the automated quality suite via CI-ready commands/scripts (typecheck, lint, tests, UI tests where applicable)
6. Commit if checks pass
7. Update `prd.json` to mark story as `passes: true`
8. If ClickUp is configured, post live task comments (`start`, `progress`, `testing`) with a `Jarvis/Codex` label, attach commit link(s), add structured task activity notes (changes + test commands/outcomes + test file paths + smoke result), link related tasks (including bug/story links), and move the story task to `testing`
9. Append learnings to `progress.txt`
10. Repeat until all stories pass or max iterations reached

## Unattended Iterations

Jarvis defaults are tuned for unattended runs:

- Codex runs with `-a never` by default, so no interactive approval pause interrupts overnight iterations.
- If a story needs a command that requires manual approval, the story should be marked in `prd.json` notes with prefix `BLOCKED:` and the command request appended to `approval-queue.txt`.
- Jarvis continues with other unblocked stories instead of waiting for approval.
- If all remaining stories are blocked, the agent emits `<promise>BLOCKED</promise>` and Jarvis exits early with a blocked status.

On context limits: each Jarvis iteration spawns a fresh Codex instance, so context does not accumulate across stories. Keeping stories small is still required.

## ClickUp Integration Defaults

When these environment variables are set, Jarvis treats ClickUp updates as required behavior for each story:

- `CLICKUP_TOKEN`
- `CLICKUP_LIST_ID` or `CLICKUP_LIST_URL`

Optional:

- `CLICKUP_STATUS_TODO` (default `to do`)
- `CLICKUP_STATUS_IN_PROGRESS` (default `in progress`)
- `CLICKUP_STATUS_DONE` (default `done`)
- `CLICKUP_STATUS_TESTING` (default `testing`)
- `CLICKUP_STATUS_DEPLOYED` (default `deployed`)
- `CLICKUP_STATUS_PLANNING` (default `planning`)
- `CLICKUP_COMMENT_AUTHOR_LABEL` (default `Jarvis/Codex`)
- `JARVIS_CLICKUP_SYNC_ON_START` (default `1`: run `scripts/clickup/sync_clickup_to_prd.sh` before iterations)
- `JARVIS_CLICKUP_SYNC_STRICT` (default `0`: set `1` to fail fast if pre-sync fails)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_ON_START` (default `0`: run `scripts/clickup/sync_jarvis_directives_to_clickup.sh` before iterations)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_STRICT` (default `0`: set `1` to fail fast if directives sync fails)
- `JARVIS_CLICKUP_DIRECTIVES_SYNC_BRANCH_POLICY` (default `main_only`: skip directives sync on feature branches)
- `JARVIS_CLICKUP_AUTO_DEPLOY_ON_MAIN` (default `0`: when `1`, only main-branch story completions auto-transition to `CLICKUP_STATUS_DEPLOYED`; non-main stays `testing`)
- `JARVIS_APPROVAL_QUEUE_FILE` (default `./approval-queue.txt`)
- `GITHUB_REPO_URL` (used for commit URL links on tasks)
- `CLICKUP_DIRECTIVES_DOC_URL` (target ClickUp Doc URL such as `https://app.clickup.com/<workspace>/v/dc/<doc_id>`)
- `CLICKUP_WORKSPACE_ID` + `CLICKUP_DIRECTIVES_DOC_ID` (alternate target configuration)
- `CLICKUP_DIRECTIVES_PAGE_ID` (optional explicit doc page id)
- `CLICKUP_DIRECTIVES_SOURCE_FILE` (optional source markdown path for directives overview)
- Per-project doc targeting lives in `scripts/clickup/.env.clickup` (keep each project’s `CLICKUP_DIRECTIVES_DOC_URL` different as needed)
- Per-story override in `prd.json`: `clickupStatus` (if set, this status is used when pushing PRD -> ClickUp before fallback to `passes` mapping)

This keeps local `prd.json` aligned with ClickUp before each run, while still preserving per-story activity updates during execution. `to do` is the active ready queue, `backlog` is future ideas, and story completion status is branch-aware by default: `main -> done`, non-main -> `testing`, and optional deploy transitions are main-only when enabled. Planning tasks are preserved as `planning` unless explicitly overridden. Jarvis must post these comments itself (never asking the user to copy updates) and should keep the final ClickUp completion comment consistent with the terminal summary. If bugs are found, create/use ClickUp task type `bug`, link bug tasks to the originating story task, and include repro context.

## Key Files

| File | Purpose |
|------|---------|
| `jarvis.sh` | The bash loop that spawns fresh Amp or Codex instances |
| `prompt.md` | Instructions given to each agent instance |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Legacy skill name for converting PRDs to JSON |
| `.claude-plugin/` | Plugin manifests for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Jarvis works |
| `scripts/clickup/` | Shared ClickUp OAuth + PRD/directives sync scripts used by project wrappers |
| `scripts/jarvis/list_runtime_errors.sh` | Summarize aggregated runtime failures reported by project runs |

## Flowchart

[![Jarvis Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new Amp instance** with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Jarvis updates the relevant `AGENTS.md` files with learnings. This is key because Amp automatically reads these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Jarvis only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- Stories should add/update as much automated test coverage as feasible and keep CI-friendly, non-interactive test commands/scripts current
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Jarvis will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories have `passes: true`, Jarvis outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See which stories are done
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## Customizing prompt.md

Edit `prompt.md` to customize Jarvis's behavior for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

When using PRD branch mode, Jarvis automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## Runtime Error Feedback

Jarvis now captures runtime failures from project runs automatically:

- project-local feed: `<project>/.jarvis/error-events.jsonl`
- core feed: `<jarvis-home>/runtime-feedback/error-events.jsonl` (when writable)

Review recent failures from Jarvis core:

```bash
./scripts/jarvis/list_runtime_errors.sh 50
```

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
