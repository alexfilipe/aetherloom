# Local-Folder Provider

Design for `LocalFolderStorageProvider` 🆕 — the first real `StorageProvider`, serving **local folders** and **NAS-backed folders through mounted macOS network filesystems** with one implementation. It is the backend for the first real sync (local↔local, milestone M4) and the base the iCloud Drive variant builds on (M6). Track context, milestones, and shared requirements: [../00-overview.md](../00-overview.md).

The design centers on one asymmetry: **reading real directories is where the safety proof lives** (is this volume mounted? is this scan complete? is absence real?), while mutating them is where atomicity lives (no torn writes, no lost content on rename, trash that can be undone). The documents split along that line.

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | The provider's shape, capability declaration, availability algorithm, scan semantics, open questions — **the spec for the read side** |
| 01-mutations-and-trash.md ⏭ | Atomic `store`, `relocate`, `makeFolder`; native trash vs `/.aetherloom/trash/` quarantine; precondition emulation |
| 02-nas-hardening.md ⏭ | Timeout-bounded enumeration, `volumeUnreachable` vs `volumeNotMounted` fidelity on SMB/NFS/AFP, mtime-granularity degradation |
| 03-testing.md ⏭ | Temp-dir rigs, the volume-inspection seam in tests, conformance harness, opt-in real-mount tests |
| [agents/](agents/) | Implementation work orders for this backend |

⏭ marks documents planned but not yet written; no work order may dispatch against a ⏭ document.

## Ground rules (in addition to [../README.md](../README.md))

- One implementation for `ProviderKind.localFolder` and `.nasFolder`; they differ only in availability probing, timeouts, capability values, and trash strategy — never in scan or mutation logic.
- The provider imports Foundation only and lives in `src/AetherloomCore/Sources/AetherloomCore/Providers/Local/`.
- Anything answering "what state is this volume in?" goes through the injected volume-inspection seam so tests can produce every unavailability reason without hardware.
- The provider never writes outside its scope except `/.aetherloom/` under its own location root (quarantine trash; built-in non-removable exclusion ✅).
