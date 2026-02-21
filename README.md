# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs [Amp](https://ampcode.com) (default) or Codex repeatedly until all PRD items are complete. Each iteration is a fresh agent instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- [Amp CLI](https://ampcode.com) installed and authenticated (default), or Codex CLI
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/
cp /path/to/ralph/prompt.md scripts/ralph/
chmod +x scripts/ralph/ralph.sh
```

### Option 2: Install skills globally (Amp only)

Copy the skills to your Amp config for use across all projects:

```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

### Option 3: Install skills for Codex

Codex only loads skills from `$CODEX_HOME/skills` (default: `~/.codex/skills`).
Symlink this repo’s skills into Codex:

```bash
./scripts/install-codex-skills.sh
```

Then restart Codex to pick up the new skills. Re-run the script any time you add or rename skills in this repo.

### Configure Amp auto-handoff (recommended, Amp only)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.
If you're using Codex, you can generate the PRD manually or with your preferred tooling.

### 3. Run Ralph

```bash
# Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Codex
RALPH_AGENT=codex ./scripts/ralph/ralph.sh [max_iterations]
```

Default is 10 iterations.

To customize Codex flags, set `RALPH_CODEX_FLAGS` (default: `--full-auto --color never`):
```bash
RALPH_CODEX_FLAGS="--full-auto -m o3" RALPH_AGENT=codex ./scripts/ralph/ralph.sh
```

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. If ClickUp is configured, move the matching `[US-xxx]` task to `in progress`
4. Implement that single story
5. Run quality checks (typecheck, tests)
6. Commit if checks pass
7. Update `prd.json` to mark story as `passes: true`
8. If ClickUp is configured, attach commit link(s), add task activity notes (changes + tests + outcome), and move task to `testing`
9. Append learnings to `progress.txt`
10. Repeat until all stories pass or max iterations reached

## ClickUp Integration Defaults

When these environment variables are set, Ralph treats ClickUp updates as required behavior for each story:

- `CLICKUP_TOKEN`
- `CLICKUP_LIST_ID` or `CLICKUP_LIST_URL`

Optional:

- `CLICKUP_STATUS_IN_PROGRESS` (default `in progress`)
- `CLICKUP_STATUS_TESTING` (default `testing`)
- `GITHUB_REPO_URL` (used for commit URL links on tasks)

This keeps your manual QA loop tight: stories move to `testing` only after code changes are committed, tests run, and task activity is updated with what changed plus test outcome.

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop that spawns fresh Amp or Codex instances |
| `prompt.md` | Instructions given to each agent instance |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Skill for converting PRDs to JSON |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

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

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because Amp automatically reads these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

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

Edit `prompt.md` to customize Ralph's behavior for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
