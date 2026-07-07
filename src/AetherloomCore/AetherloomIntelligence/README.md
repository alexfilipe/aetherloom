# AetherloomIntelligence

`AetherloomIntelligence` keeps optional on-device model adapters outside `AetherloomCore`.

The core target owns advisory protocols, closed safe options, validation, deterministic heuristics, and orchestration. This target may import Apple model frameworks behind `#if canImport(FoundationModels)` and returns no advice when the framework or local model is unavailable.

Apps register an advisor by constructing `SyncOrchestrator(..., advisor:)`. Advice is always text plus a ranking over engine-provided options; it never changes a plan, approval, conflict resolution state, or execution operation.

Model-backed tests are opt-in only:

```bash
AETHERLOOM_ENABLE_MODEL_TESTS=1 swift test --package-path src/AetherloomCore
```

Default tests use fakes and deterministic heuristics only.
