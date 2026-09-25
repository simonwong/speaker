# Issue Tracker

Speaker tracks work in Linear team `Personal`, project `Speaker`. Use the Linear tools and resolve these names to current IDs before writing. If lookup is ambiguous, ask the user to identify the target. Scope issue searches and new issues to this project.

GitHub hosts the repository and pull requests. Pull requests do not enter the default feature-request or triage queue. When a request explicitly names a GitHub issue or PR, read or triage that item as requested.

## Read and publish

- Fetch a Linear issue with its description, state, team, project, labels, assignee, relations, and all comments before deriving a spec, ticket, or implementation. Follow pagination. Use Linear identifiers such as `IND-42` or full URLs; a bare `#42` is not a Linear identifier. Resolve its tracker and kind before acting.
- Search this project for existing work before creating an issue. Publication cardinality comes from the invoking skill and its artifacts. Create the corresponding issue for each spec or ticket in `Personal` / `Speaker`, default its state to `Backlog`, and apply its required canonical triage label. Honor an explicitly requested state.
- Read current state before updates and preserve unrelated fields, labels, and relations. Resolve available team statuses and labels before applying them; see `triage-labels.md` for label roles.
- When a skill says “fetch the relevant ticket,” use the issue body and every comment as source material.

A read is complete when the issue's current state, project, labels, description, relations, and all comments are accounted for. A publication is complete when Linear readback confirms every required issue's final title, description, team, project, state, and expected label.

## GitHub-linked issues

When a Linear issue links to a GitHub issue, read both issues and their latest comments before resolving either side. Record the resolution and evidence in Linear, set `Done` for completed work or `Canceled` for a decision not to proceed, and close the linked GitHub issue with `gh issue close <number> --repo simonwong/speaker --reason completed` or `--reason 'not planned'`, respectively. Include a GitHub resolution comment linking to Linear and the evidence. If GitHub is already closed, reconcile Linear with its actual resolution; a merged PR alone does not prove acceptance criteria are met.

When reopening linked work, reopen both sides and restore the appropriate Linear state. Read back both systems after each transition. Report completion only when their states agree; if one write fails, report the remaining synchronization step and retry that step without duplicating the resolution comment. These are agent workflow obligations; links and labels do not install background synchronization.

## Wayfinding

A wayfinding map is one Linear issue labeled `wayfinder:map`. Its child tickets belong to the same project, use the map's issue ID as `parentId`, and carry `wayfinder:<type>` (`research`, `prototype`, `grilling`, or `task`). Reuse exact existing workspace-level labels; create missing labels at workspace scope by omitting `teamId`. The map owns Notes, Decisions-so-far, and Fog, and lists children in frontier order using Linear identifiers.

Represent blocking through Linear's native `blockedBy` / `blocks` relations. Resolve referenced issues before writing relations and preserve unrelated edges.

The frontier contains unfinished, uncanceled, unassigned children whose blockers are all `Done`. A canceled or duplicate blocker requires its dependency to be resolved before the child becomes eligible. Claim the first child in map order by assigning it to the driving developer; this assignment is the session's first write. Resolve it by adding the answer, setting the child to `Done`, and appending a durable context pointer to the map's Decisions-so-far.

A wayfinding transition is complete when child state, assignee, parent, dependency edges, and map pointer agree in Linear's current readback.
