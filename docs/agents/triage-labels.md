# Triage Labels

Use these canonical roles and exact Linear issue label strings:

| Label | Apply when |
| --- | --- |
| `needs-triage` | Maintainer evaluation is next. |
| `needs-info` | Reporter input blocks progress. |
| `ready-for-agent` | Specification is complete and an unattended agent can implement it. |
| `ready-for-human` | Human implementation or authority is required. |
| `wontfix` | Maintainers decided not to act. |

Resolve workspace-level labels; reuse exact matches and create missing labels at workspace scope by omitting `teamId`. Replace only canonical triage labels and preserve unrelated labels. Labels describe the next actor; Linear workflow states describe progress. A `wontfix` decision uses the `Canceled` state.

A triage change is complete when exactly one canonical role describes the next actor and Linear readback shows that label and the intended workflow state.
