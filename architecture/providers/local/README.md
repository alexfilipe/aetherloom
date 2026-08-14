# Local-Folder Provider

Design for `LocalFolderStorageProvider` ✅ — the first real `StorageProvider`, with implementation and temporary-directory core tests already present. It is the backend for the Local Workspace MVP. The same architecture may serve mounted NAS filesystems later, but NAS qualification is not part of this MVP. Track context and current status: [../00-overview.md](../00-overview.md).

The design centers on one asymmetry: **reading real directories is where the safety proof lives** (is this volume mounted? is this scan complete? is absence real?), while mutating them is where atomicity lives (no torn writes, no lost content on rename, trash that can be undone). The documents split along that line.

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | Implemented provider shape, capabilities, availability, scanning, mutations, and ownership |
| [01-package-and-metadata-safety.md](01-package-and-metadata-safety.md) | Normative MVP policy for packages, xattrs, Finder metadata, and resource forks |
| 02-nas-hardening.md ⏭ | Timeout-bounded enumeration, `volumeUnreachable` vs `volumeNotMounted` fidelity on SMB/NFS/AFP, mtime-granularity degradation |
| [agents/](agents/) | Implementation work orders for this backend |

⏭ marks documents planned but not yet written; no work order may dispatch against a ⏭ document.

## Ground rules (in addition to [../README.md](../README.md))

- One implementation for `ProviderKind.localFolder` and `.nasFolder`; they differ only in availability probing, timeouts, capability values, and trash strategy — never in scan or mutation logic.
- The provider imports Foundation only and lives in `src/AetherloomCore/Sources/AetherloomCore/Providers/Local/`.
- Anything answering "what state is this volume in?" goes through the injected volume-inspection seam so tests can produce every unavailability reason without hardware.
- The provider never writes outside its scope except `/.aetherloom/` under its own location root (quarantine trash; built-in non-removable exclusion ✅).
