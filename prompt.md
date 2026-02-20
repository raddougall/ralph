# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.
You are authorized to create git commits as needed when work passes checks.

## Your Task

Before starting, check whether a relevant skill exists under `skills/` in this repo. If so, read its `SKILL.md` and follow those instructions. Then read `AGENTS.md` and follow its constraints.

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false`
5. Implement that single user story
6. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
7. Update AGENTS.md files if you discover reusable patterns (see below)
8. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]`
9. Update the PRD to set `passes: true` for the completed story
10. Append your progress to `progress.txt`

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
Session: (Amp thread URL or Codex session ID if available)
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

Include a session link or ID when available so future iterations can reference prior work if needed.

The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist). This section should consolidate the most important learnings:

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
- Example: Export types from actions.ts for UI components
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update AGENTS.md Files

Before committing, check if any edited files have learnings worth preserving in nearby AGENTS.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing AGENTS.md** - Look for AGENTS.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good AGENTS.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

Only update AGENTS.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Every story must add or update automated tests for the changed behavior; do not rely on manual-only validation.
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Host System Mutation Guardrail (Mandatory)

- Never run host-level package manager commands (`brew`, `apt`, `apt-get`, `yum`, `dnf`, `pacman`, `apk`, `port`, `choco`, `winget`) without explicit user approval in the active session.
- If such a command is required, stop and report exactly what needs approval instead of running it.
- Do not bypass this rule by calling absolute paths (for example `/opt/homebrew/bin/brew`).
- This environment blocks those commands by default unless `RALPH_ALLOW_SYSTEM_CHANGES=1` is explicitly set by the user.

## Git Sandbox Troubleshooting

If you see "Operation not permitted" when writing to `.git/*` (e.g., `index.lock` or `refs/heads/*`), the sandbox is blocking git writes. Re-run git commands that write to `.git` (switch/checkout/branch/commit/add) with elevated permissions. If escalation still fails, ask the user to run git commands locally outside the agent sandbox. For slash-named branches (e.g., `ralph/*`), ensure `.git/refs/heads/ralph` is not a file; rename it and create the directory before retrying.

## Browser Testing (Required for Frontend Stories)

For any story that changes UI, you MUST verify it works in the browser:

1. If a browser automation tool/skill is available, load it
2. Navigate to the relevant page
3. Verify the UI changes work as expected
4. Add or update automated UI test coverage for the changed behavior
5. Take a screenshot if helpful for the progress log
6. If no browser tool is available, still deliver automated test coverage and log the browser tooling gap

A frontend story is NOT complete until automated coverage for the UI change is in place.

## Stop Condition

After completing a user story, check if ALL stories have `passes: true`.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false`, end your response normally (another iteration will pick up the next story).

## Important

- Work on ONE story per iteration
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
