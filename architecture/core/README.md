# Aetherloom Core Architecture

This directory is the canonical design for Aetherloom's **provider-independent sync engine** — written as the architecture *should be*, not as the current scaffold happens to be. Where the existing code in `src/AetherloomCore/` differs, each document says so, and [11-migration.md](11-migration.md) gives the complete old → new mapping and phase plan.

Two audiences:

1. **Developers** — read the numbered documents in order. 00–02 give vocabulary and boundaries, 03–05 are the engine's heart, 06–09 the surfaces, 10–11 verification and migration.
2. **Implementation agents** (Claude, GPT-5.5, …) — each file under [agents/](agents/) is a self-contained work order for one phase. See [agents/README.md](agents/README.md) for the dependency graph.

## Scope

In scope now: the core engine against **fake providers** — domain model, provider abstraction, reconciliation, planning and gating, execution (staging, journal), previews and approval, on-device AI conflict advice (advisory only), observability, persistence interfaces, tests.

Out of scope now: OAuth, real Google Drive / OneDrive / Dropbox / iCloud integrations, filesystem watchers, background sync, menu bar agents, App Store sandboxing, wiring the demo SwiftUI shell.

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | Safety invariants, layering, pipeline, architecture decisions & rejected alternatives |
| [01-domain-model.md](01-domain-model.md) | The vocabulary: paths, versions, observations, base records, locations, sync sets |
| [02-provider-abstraction.md](02-provider-abstraction.md) | `StorageProvider`, availability taxonomy, capabilities, snapshots, fakes |
| [03-reconciliation.md](03-reconciliation.md) | The pure per-item decision table — the heart of the engine |
| [04-planning-and-gating.md](04-planning-and-gating.md) | Lowering verdicts to operations; refusals vs holds; mass-change thresholds; fingerprints |
| [05-execution-and-orchestration.md](05-execution-and-orchestration.md) | Content staging, operation schedule, run journal, crash recovery, the orchestrator |
| [06-preview-and-approval.md](06-preview-and-approval.md) | `ChangePreview` from decisions; `PlanApproval`; UI contract |
| [07-ai-conflict-advisor.md](07-ai-conflict-advisor.md) | On-device advisory architecture; hard boundaries |
| [08-observability.md](08-observability.md) | Activity log + run journal as the accountability story |
| [09-persistence.md](09-persistence.md) | Store interfaces; file-backed now, SQLite later |
| [10-testing-strategy.md](10-testing-strategy.md) | Decision-table exhaustion, simulation testing, coverage matrix |
| [11-migration.md](11-migration.md) | **How to change the current code**: old → new map, phases, invariant-preserving order |
| [agents/](agents/) | Nine self-contained implementation work orders |

## Ground rules

- **Data safety beats everything.** The invariants in [00-overview.md](00-overview.md#safety-invariants) override any other statement in these documents.
- All sync logic lives in `AetherloomCore`; the SwiftUI app target stays UI-only (today it is a demo shell for the website — leave it unwired).
- The reconciliation and planning layers are **pure**: values in, values out, no I/O, no clock reads (time is injected). Side effects live only in providers, the executor, and stores.
- Core tests never touch the network, real cloud roots, or real user folders.
- The AI advisor can never originate, approve, or execute an action.

## Status legend

- ✅ **Exists today** in `AetherloomCore` (possibly under an old name — see [11-migration.md](11-migration.md)).
- 🔁 **Reshape** — today's code has the behavior; the structure changes.
- 🆕 **New** — designed here, not yet implemented.
