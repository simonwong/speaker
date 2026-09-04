# Speaker Documentation

Use this index to load only the branch relevant to the task. Durable decisions and evidence belong here; temporary exploration and completed implementation tickets do not.

## Product

- **Voice Input behavior or acceptance:** [`specs/voice-input.md`](specs/voice-input.md).
- **Cross-application delivery evidence:** [`compatibility.md`](compatibility.md).
- **Release gates and remaining evidence:** [`production-readiness.md`](production-readiness.md).

## Architecture

- **Module, interface, seam, adapter, or invariant changes:** [`architecture.md`](architecture.md).
- **Reconsidering a load-bearing decision:** [`adr/README.md`](adr/README.md), then every relevant ADR.
- **Provider or platform contract changes:** the dated pages under [`research/`](research/); recheck their primary sources before changing an adapter.

## Prototypes

Throwaway HTML mockups under [`prototypes/`](prototypes/). Each one answers a single design question and is never product truth; the answer that survived lives in [`specs/voice-input.md`](specs/voice-input.md) and the App itself.

- [`prototypes/recording-hud-prototype.html`](prototypes/recording-hud-prototype.html) — how much should the recording HUD say over a target window, and what do the Pending Copy row and the error row look like when delivery does not happen?
- [`prototypes/main-window-prototype.html`](prototypes/main-window-prototype.html) — which tabs does the main window need, and what belongs in Overview, History, Settings, and Dictionary?
- [`prototypes/main-window-redesign-prototype.html`](prototypes/main-window-redesign-prototype.html) — how do history rows, per-session Stage Result detail, and Refinement Mode authoring fit into the redesigned main window?
- [`prototypes/overview-redesign-prototype.html`](prototypes/overview-redesign-prototype.html) — which cumulative usage figures make Overview worth opening, and how should it behave when empty or resized?
- [`prototypes/dictionary-redesign-prototype.html`](prototypes/dictionary-redesign-prototype.html) — can the Personal Dictionary be a plain Entry list, with no alias or replacement columns?
- [`prototypes/settings-about-ia-prototype.html`](prototypes/settings-about-ia-prototype.html) — where is the line between Settings as pure preferences and About as privacy boundaries, local data, and version?

## Agent workflow

- **Build, test, launch, bundle, provider smoke, or release:** [`agents/development.md`](agents/development.md).
- **Domain vocabulary or ADR work:** [`agents/domain.md`](agents/domain.md).
- **Issue publication or triage:** [`agents/issue-tracker.md`](agents/issue-tracker.md) and [`agents/triage-labels.md`](agents/triage-labels.md).
- **Production distribution:** [`releasing.md`](releasing.md).
