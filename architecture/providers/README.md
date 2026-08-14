# Aetherloom Provider Architecture

This directory is the canonical design for Aetherloom's **real storage-provider integrations**. `LocalFolderStorageProvider` and its core tests exist today; the production app still runs `DemoEngineSession`, so no app feature yet operates on selected real folders. [01-workspace-engine-session.md](01-workspace-engine-session.md) defines the boundary that moves the production app to real local data.

Two audiences:

1. **Developers** — read [00-overview.md](00-overview.md) first (roadmap, shared requirements, the conformance suite), then the per-backend directory you're working in.
2. **Implementation agents** (Claude, Codex, GPT-5.5, …) — each file under [agents/](agents/) and under a backend's `agents/` is a self-contained work order. See [agents/README.md](agents/README.md) for the dispatch graph across the whole track.

## Scope

In scope now: the local-folder arbitrary-folder safety policy, durable workspace persistence, `WorkspaceEngineSession`, and real app enrollment for manually confirmed sync between two selected local folders.

Future after the local alpha: NAS hardening and the iCloud Drive local-folder variant (dataless placeholders, materialization), each behind its own accepted architecture and work order.

Out of scope now: OAuth and cloud SDKs (OneDrive, Google Drive, Dropbox), FSEvents change hints, background/scheduled sync, whole-drive or NAS qualification, SQLite, migration UI, and App Store distribution. The app remains sandboxed; read/write folder authority and app-scoped bookmarks are part of the local MVP.

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | Roadmap and milestones, shared normative requirements for every real provider, the conformance suite, targets and layering, decisions & rejected alternatives |
| [01-workspace-engine-session.md](01-workspace-engine-session.md) | Normative production session, sandbox/bookmark authority, identity/overlap, durable workspace, relaunch, and recovery contract |
| [local/](local/README.md) | The implemented local-folder provider, its arbitrary-folder fidelity boundary, and future NAS use |
| icloud/ ⏭ | iCloud Drive as a local-folder variant: placeholders, download status, materialization |
| onedrive/, gdrive/, dropbox/ ⏭ | Cloud integrations — much later, per the development order |
| [agents/local-workspace-mvp.md](agents/local-workspace-mvp.md) | Sole ordered L1–L6 dispatch map, acceptance ownership, and validation gates |

⏭ marks documents planned but not yet written; no work order may dispatch against a ⏭ document.

## Ground rules

- **Safety invariants** ([../core/00-overview.md](../core/00-overview.md#safety-invariants)) bind every provider. The two that dominate this track: absence caused by failure is never deletion, and no permanent-delete path may exist on any implementation.
- **Real providers are held to the fake's contract.** Every implementation passes the conformance suite ([00-overview.md §3](00-overview.md#3-the-conformance-suite)) before the orchestrator may compose it.
- **Tests never touch real user folders, real mounts, or the network by default.** Filesystem tests run in temporary directories they create and remove; unavailability states are produced through injected seams, not by unplugging hardware. Opt-in real-mount tests are environment-gated and clearly named.
- **Capabilities are declared honestly and conservatively.** When a backend cannot prove a capability, it declares `false` and lets the engine degrade toward preservation ([../core/02-provider-abstraction.md §3](../core/02-provider-abstraction.md)).
- The engine never branches on `ProviderKind`; providers are chosen at composition time and differ only through `StorageProvider`, capabilities, and availability behavior.

## Status legend

- ✅ **Exists today** in `src/` (including the real local provider and its core tests).
- 🆕 **New** — designed here, not yet implemented.
- ⏭ **Planned** — deferred to a later phase of this track; design not yet written.
