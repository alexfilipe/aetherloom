# Aetherloom Provider Architecture

This directory is the canonical design for Aetherloom's **real storage-provider integrations** — the track that moves the boundary named in [../ui/11-functioning-vs-placeholder.md](../ui/11-functioning-vs-placeholder.md): *"No functioning feature touches the network or real user files yet — that boundary moves only when `WorkspaceEngineSession` exists."* The engine ([../core/](../core/README.md)) is hardened against fake providers; this track builds the providers that make it sync real bytes, in the order that adds the fewest unknowns per step.

Two audiences:

1. **Developers** — read [00-overview.md](00-overview.md) first (roadmap, shared requirements, the conformance suite), then the per-backend directory you're working in.
2. **Implementation agents** (Claude, Codex, GPT-5.5, …) — each file under [agents/](agents/) and under a backend's `agents/` is a self-contained work order. See [agents/README.md](agents/README.md) for the dispatch graph across the whole track.

## Scope

In scope now: the provider conformance suite, the local-folder provider (which also serves NAS-backed folders through mounted network filesystems), and `WorkspaceEngineSession` — real providers composed with the file-backed stores so the app performs its first real sync between two local folders.

Next after that: the iCloud Drive local-folder variant (dataless placeholders, materialization).

Out of scope now: OAuth and cloud SDKs (OneDrive, Google Drive, Dropbox), FSEvents change hints, background sync, App Store sandboxing, SQLite (the JSON file stores in [../core/09-persistence.md](../core/09-persistence.md) carry real syncs until scale says otherwise).

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | Roadmap and milestones, shared normative requirements for every real provider, the conformance suite, targets and layering, decisions & rejected alternatives |
| 01-workspace-session.md ⏭ | `WorkspaceEngineSession`: composing real providers with file-backed stores, folder selection, workspace persistence, coexistence with the demo session |
| [local/](local/README.md) | The local-folder provider, serving local folders and NAS-backed folders — the first real backend |
| icloud/ ⏭ | iCloud Drive as a local-folder variant: placeholders, download status, materialization |
| onedrive/, gdrive/, dropbox/ ⏭ | Cloud integrations — much later, per the development order |
| [agents/](agents/) | Track-level implementation work orders and the cross-track dispatch graph |

⏭ marks documents planned but not yet written; no work order may dispatch against a ⏭ document.

## Ground rules

- **Safety invariants** ([../core/00-overview.md](../core/00-overview.md#safety-invariants)) bind every provider. The two that dominate this track: absence caused by failure is never deletion, and no permanent-delete path may exist on any implementation.
- **Real providers are held to the fake's contract.** Every implementation passes the conformance suite ([00-overview.md §3](00-overview.md#3-the-conformance-suite)) before the orchestrator may compose it.
- **Tests never touch real user folders, real mounts, or the network by default.** Filesystem tests run in temporary directories they create and remove; unavailability states are produced through injected seams, not by unplugging hardware. Opt-in real-mount tests are environment-gated and clearly named.
- **Capabilities are declared honestly and conservatively.** When a backend cannot prove a capability, it declares `false` and lets the engine degrade toward preservation ([../core/02-provider-abstraction.md §3](../core/02-provider-abstraction.md)).
- The engine never branches on `ProviderKind`; providers are chosen at composition time and differ only through `StorageProvider`, capabilities, and availability behavior.

## Status legend

- ✅ **Exists today** in `src/` (the protocol, the fakes, the file-backed stores).
- 🆕 **New** — designed here, not yet implemented.
- ⏭ **Planned** — deferred to a later phase of this track; design not yet written.
