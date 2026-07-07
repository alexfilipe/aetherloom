# Aetherloom Architecture

Canonical design documentation for Aetherloom, split by layer:

| Area | Contents |
| --- | --- |
| [core/](core/README.md) | The provider-independent sync engine: domain model, provider abstraction, reconciliation, planning and gating, execution, previews and approval, on-device AI advice, observability, persistence, testing, migration. Implementation work orders in [core/agents/](core/agents/README.md). |
| [ui/](ui/README.md) | The native macOS SwiftUI app: design system, shell and navigation, the engine bridge (real `AetherloomCore` behind a demo world), per-screen specifications, the functioning-vs-placeholder matrix, testing. Implementation work orders in [ui/agents/](ui/agents/README.md). |

Reading order for newcomers: [core/00-overview.md](core/00-overview.md) first — the safety invariants there are the constitution for everything, including the UI — then either track's README.

Both tracks share one contract: **the engine decides, the UI presents.** No sync rules in SwiftUI views; no UI concerns in `AetherloomCore`. The seam between them is specified in [ui/03-engine-session.md](ui/03-engine-session.md).
