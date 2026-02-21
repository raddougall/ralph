# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false`
5. If ClickUp is configured (see below), find the matching task for the story and move it to `in progress`
6. Implement that single user story
7. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
8. Update CLAUDE.md files if you discover reusable patterns (see below)
9. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]` (append ` | ClickUp: <task_id>` when task id is known)
10. Update the PRD to set `passes: true` for the completed story
11. Append your progress to `progress.txt`
12. If ClickUp is configured, attach commit URL(s), add an activity comment with summary + tests + outcome, then move task to `testing`

## ClickUp Workflow (Required When Configured)

If these env vars exist, you MUST keep ClickUp in sync for every story:

- `CLICKUP_TOKEN`
- `CLICKUP_LIST_ID` or `CLICKUP_LIST_URL`

Optional env vars:

- `CLICKUP_API_BASE` (default: `https://api.clickup.com/api/v2`)
- `CLICKUP_STATUS_IN_PROGRESS` (default: `in progress`)
- `CLICKUP_STATUS_TESTING` (default: `testing`)
- `GITHUB_REPO_URL` (for commit links; if missing, derive from `git remote origin`)

Required behavior per story:

1. Resolve story task in the target list by name prefix `[US-xxx]`.
2. Move task to `in progress` when implementation starts.
3. After commit, add GitHub commit URL to the task (description section like `GitHub Commits:` or comment).
4. Add an activity comment with:
   - what you changed
   - what tests you ran
   - outcome/result
5. Move task to `testing` when it is ready for manual validation.

If ClickUp config is missing, continue normal implementation and explicitly report ClickUp was skipped due to missing configuration.

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

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

## Update CLAUDE.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CLAUDE.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CLAUDE.md** - Look for CLAUDE.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good CLAUDE.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

Only update CLAUDE.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Every story must add or update automated tests for the changed behavior; do not rely on manual-only validation.
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Browser Testing (If Available)

For any story that changes UI, verify it works in the browser if you have browser testing tools configured (e.g., via MCP):

1. Navigate to the relevant page
2. Verify the UI changes work as expected
3. Take a screenshot if helpful for the progress log
4. Add or update automated UI test coverage for the changed behavior

If no browser tools are available, still deliver automated coverage and note the browser tooling gap.

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
