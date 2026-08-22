# Domain Documentation

Speaker is a single-context repository. `CONTEXT.md` is the glossary; `docs/adr/` records accepted load-bearing decisions.

## Consume

Before exploring or naming domain behavior:

1. Read `CONTEXT.md` completely.
2. Read the ADR index and every ADR whose decision touches the task.
3. Use glossary terms in code, specs, tests, issues, commits, and PRs. Avoid each term's listed synonyms.
4. Surface any proposed contradiction with an accepted ADR and explain why the decision should reopen.

Context gathering is complete when every domain concept in the proposed change maps to the glossary and every relevant accepted ADR is either preserved or explicitly challenged.

## Maintain

Add a glossary entry only when the work resolves a durable domain concept that existing terms cannot express. Add an ADR only when the work resolves a load-bearing decision future architecture work might otherwise relitigate. Keep definitions, invariants, and avoided synonyms together; keep superseded ADRs and link their replacements.

Domain documentation is complete when one authoritative entry owns each changed term or decision and the implementation, tests, issue, commit, and PR use that language consistently.
