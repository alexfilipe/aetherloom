# Aetherloom Architecture

Canonical design documentation for Aetherloom, split by layer:

| Area | Contents |
| --- | --- |
| [core/](core/README.md) | The provider-independent sync engine: domain model, provider abstraction, reconciliation, planning and gating, execution, previews and approval, on-device AI advice, observability, persistence, testing, migration. Implementation work orders in [core/agents/](core/agents/README.md). |
| [ui/](ui/README.md) | The native macOS SwiftUI app: design system, shell and navigation, the engine bridge (real `AetherloomCore` behind a demo world), per-screen specifications, the functioning-vs-placeholder matrix, testing. Implementation work orders in [ui/agents/](ui/agents/README.md). |
| [providers/](providers/README.md) | Real storage-provider integrations: the implemented local provider, the normative Local Workspace production contract, the serial L1–L6 work stack, and later NAS/iCloud/cloud work. |
| [orchestration/](orchestration/README.md) | The evaluation-loop development framework for every feature and PR: define, implement, evaluate, decide; bounded subagents and reviews; practical merge cutoffs; writer/test locks; and durable [cutoff decisions](orchestration/cutoffs/README.md). |

Reading order for newcomers: [core/00-overview.md](core/00-overview.md) first — the safety invariants there are the constitution for everything, including the UI — then any track's README.

The tracks share two contracts: **the engine decides, the UI presents** (no sync rules in SwiftUI views; no UI concerns in `AetherloomCore`; the seam is specified in [ui/03-engine-session.md](ui/03-engine-session.md)), and **every real provider is held to the fake's contract** (the conformance suite in [providers/00-overview.md](providers/00-overview.md) is the merge gate for any backend the orchestrator composes).

Use [orchestration/README.md](orchestration/README.md) for every feature and PR, scaling the loop to risk. Record material finish, deferral, retry, freeze/reopen, and routing decisions in [orchestration/cutoffs/DECISIONS.md](orchestration/cutoffs/DECISIONS.md), in the format defined by [orchestration/cutoffs/README.md](orchestration/cutoffs/README.md). That log is kept short by retiring closed decisions once their open residue is carried forward into its backlog.
