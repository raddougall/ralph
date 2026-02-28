# Jarvis Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Pick the **highest priority** user story where `passes: false` and `notes` does not start with `BLOCKED:`
5. If ClickUp is configured (see below), find the matching task for the story, move it from `to do` to `in progress`, and post a kickoff activity comment with the implementation plan
6. Implement that single user story and post ClickUp progress comments at major milestones (plan complete, code complete, tests complete)
7. Run the full automated quality suite for the changed scope using CI-ready commands/scripts (typecheck, lint, tests, UI tests where applicable)
8. Update CLAUDE.md files if you discover reusable patterns (see below)
9. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]` (append ` | ClickUp: <task_id>` when task id is known)
10. Update the PRD to set `passes: true` for the completed story
11. Append your progress to `progress.txt`
12. If ClickUp is configured, attach commit URL(s), add a final structured activity comment that matches your terminal summary, create/link bug tasks when relevant, then move the story task to `testing`

## Project Isolation (Mandatory)

- Treat the project directory (`JARVIS_PROJECT_DIR`) as the only writable workspace during story work.
- Project story runs MUST be writable inside `JARVIS_PROJECT_DIR` (code edits, test artifacts, git metadata, and ClickUp/task state updates are expected and allowed).
- Read-only restrictions apply only to files outside the active project root (plus explicit system-mutation guardrails), not inside the project itself.
- You may read shared Jarvis files (prompts/scripts/skills) for execution context, but do not edit Jarvis itself from a project run.
- Never modify files outside the active project root unless the user explicitly asks for that exact cross-repo change.

## ClickUp Workflow (Required When Configured)

If these env vars exist, you MUST keep ClickUp in sync for every story:

- `CLICKUP_TOKEN`
- `CLICKUP_LIST_ID` or `CLICKUP_LIST_URL`

Optional env vars:

- `CLICKUP_API_BASE` (default: `https://api.clickup.com/api/v2`)
- `CLICKUP_STATUS_TODO` (default: `to do`)
- `JARVIS_STORY_ORDER_MODE` (default: `priority`; set `clickup` to pick next story by ClickUp manual order)
- `CLICKUP_STATUS_IN_PROGRESS` (default: `in progress`)
- `CLICKUP_STATUS_TESTING` (default: `testing`)
- `CLICKUP_COMMENT_AUTHOR_LABEL` (default: `Jarvis/Codex`; prepended to every task comment so updates are visibly automated)
- `GITHUB_REPO_URL` (for commit links; if missing, derive from `git remote origin`)
- `JARVIS_CLICKUP_SYNC_ON_START` (default: `1`, pre-syncs ClickUp `[US-xxx]` tasks into local `prd.json` when `scripts/clickup/sync_clickup_to_prd.sh` is available)
- `JARVIS_CLICKUP_SYNC_STRICT` (default: `0`, set `1` to fail the run if pre-sync fails)
- `JARVIS_APPROVAL_QUEUE_FILE` (default: `./approval-queue.txt`)
- `JARVIS_PROJECT_SYNC_ON_START` (default: `1`, refresh project-local wrappers/docs/templates from Jarvis master before story work)
- `JARVIS_PROJECT_SYNC_STRICT` (default: `0`, set `1` to fail the run if project sync fails)

Project sync must be additive and safe:
- never overwrite existing project secret values (for example `.env` files)
- only add missing defaults and refresh shared wrappers/docs

Required behavior per story:

1. Resolve story task in the target list by name prefix `[US-xxx]`.
2. Treat `to do` as the ready-to-work queue and keep `backlog` for future ideas only.
3. Move task to `in progress` when implementation starts.
4. Immediately post a kickoff comment containing the implementation plan. Do this yourself; never ask the user to copy/paste updates into ClickUp.
5. Post progress comments during execution at major milestones (after plan/context, after code edits, after automated tests).
6. After commit, add GitHub commit URL to the task (use task link API when authorized; if link API fails, include URL in comment).
7. Add a final activity comment with:
   - what you changed
   - what tests you ran (commands + pass/fail outcome)
   - where the automated test files are (repo-relative file paths for added/updated coverage)
   - any manual smoke checks performed (or explicitly state none)
   - outcome/result
8. Ensure the final activity comment content is consistent with your final user-facing summary (same key changes, tests, outcomes).
9. Prefix each task comment with `[<CLICKUP_COMMENT_AUTHOR_LABEL>]` so comments are clearly automated by Jarvis/Codex.
10. Link related tasks when work has dependency/traceability context (for example, bug <-> originating user story).
11. Bugs must use ClickUp task type `bug` (not story/task type), include repro details, and link back to the related `[US-xxx]` story task.
12. Move the story task to `testing` when it is ready for manual validation.

Use these activity comment templates:
- `Kickoff:` `[Jarvis/Codex][US-xxx][start]` + `Plan:` + `Scope/Assumptions:`
- `Progress:` `[Jarvis/Codex][US-xxx][progress]` + `Now:` + `Next:`
- `Completion:` `[Jarvis/Codex][US-xxx][testing]` + `Changed:` + `Tests Run:` + `Test Files:` + `Smoke Check:` + `Outcome:`

If ClickUp config is missing, continue normal implementation and explicitly report ClickUp was skipped due to missing configuration.

## Unattended Execution (Mandatory)

- Do not block waiting for interactive approval prompts. Jarvis runs unattended.
- Git commands within the active project repo are allowed and should be attempted normally.
- If a required command cannot run without manual approval (or host-level access), do all of the following:
  1. Append an entry to `JARVIS_APPROVAL_QUEUE_FILE` (or `./approval-queue.txt`) with timestamp, story id, exact command, reason, and fallback attempted.
  2. Mark that story `notes` with prefix `BLOCKED:` plus a short reason and queue-file reference.
  3. Keep `passes: false` for that story.
  4. Continue with the next highest-priority unblocked story.
- Never use approval blocking as a reason to stop the full run while unblocked stories remain.

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

- ALL commits must pass your project's automated quality checks (typecheck, lint, test)
- Every story must maximize automated coverage feasible for the changed scope and add or update tests for changed behavior; do not rely on manual-only validation.
- If CI-ready test scripts/commands are missing for changed behavior, create or update them so tests can run non-interactively in continuous integration.
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

For local smoke tests:
- Localhost-only browser actions (for example `http://127.0.0.1` / `http://localhost`) are allowed without pausing for per-click permission prompts.
- Keep local server testing sandboxed to the project.
- If you start local servers/processes for testing, you MUST stop them before ending the story iteration (no lingering dev servers).

## Stop Condition

After completing a user story, check the remaining story state.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false` but at least one unblocked story remains, end your response normally (another iteration will pick up the next story).

If remaining stories are all blocked by approval requirements, reply with:
<promise>BLOCKED</promise>

## Important

- Complete at most ONE story per iteration (you may mark additional stories as `BLOCKED:` to keep queueing approvals)
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
