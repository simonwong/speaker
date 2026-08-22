# Issue Tracker

Speaker uses GitHub Issues in `simonwong/speaker`; use `gh` from this clone so the remote resolves the repository. Pull requests do not enter the default feature-request or triage queue. When a request explicitly names a PR, read or triage that PR as requested.

## Read and publish

- Fetch an issue with its body, labels, and all comments before deriving a spec, ticket, or implementation. A bare `#42` may be an issue or PR because GitHub shares one number space; resolve the kind before acting.
- Publication cardinality comes from the invoking skill and its artifacts. Create the corresponding issue for each spec or ticket and apply its required canonical triage label.
- When a skill says “fetch the relevant ticket,” use the issue body and every comment as source material.

A read is complete when issue kind, current state, labels, body, and all comments are accounted for. A publication is complete when every required issue exists with its final title/body and expected label.

## Wayfinding

A wayfinding map is one issue labeled `wayfinder:map`. Its child tickets are GitHub sub-issues labeled `wayfinder:<type>` (`research`, `prototype`, `grilling`, or `task`). The map owns Notes, Decisions-so-far, and Fog. Where sub-issues are unavailable, list children in a map task list and put `Part of #<map>` at the top of each child.

Represent blocking through GitHub issue dependencies. The dependency endpoint expects the blocker's numeric database `id`, not its issue number or GraphQL `node_id`. If repository support is unavailable, place `Blocked by: #<n>` at the top of the child body.

The frontier contains open, unassigned children whose blockers are all closed. Claim the first child in map order by assigning it to the driving developer; this assignment is the session's first write. Resolve it by adding the answer, closing the child, and appending a durable context pointer to the map's Decisions-so-far.

A wayfinding transition is complete when child state, assignee, dependency edges, and map pointer agree in GitHub's current readback.
