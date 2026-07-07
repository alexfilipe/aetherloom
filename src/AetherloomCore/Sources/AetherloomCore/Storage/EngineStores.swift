import Foundation

public struct EngineStores: Sendable {
    public var baseRecords: any BaseRecordStore
    public var journal: any RunJournalStore
    public var conflicts: any ConflictStore
    public var adviceCache: any AdviceCacheStore
    public var activity: any ActivityStore
    public var locations: any LocationRegistry

    public init(
        baseRecords: any BaseRecordStore,
        journal: any RunJournalStore,
        conflicts: any ConflictStore,
        adviceCache: any AdviceCacheStore,
        activity: any ActivityStore,
        locations: any LocationRegistry
    ) {
        self.baseRecords = baseRecords
        self.journal = journal
        self.conflicts = conflicts
        self.adviceCache = adviceCache
        self.activity = activity
        self.locations = locations
    }

    public static func inMemory(activityCapacity: Int = 10_000) -> EngineStores {
        EngineStores(
            baseRecords: InMemoryBaseRecordStore(),
            journal: InMemoryRunJournalStore(),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(capacity: activityCapacity),
            locations: InMemoryLocationRegistry()
        )
    }
}

public protocol BaseRecordStore: Sendable {
    func records(for syncSetID: UUID) async throws -> [BaseRecord]
    func apply(_ update: BaseRecordUpdate) async throws
}

public protocol RunJournalStore: Sendable {
    func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws
    func append(_ event: JournalEvent, runID: UUID) async throws
    func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay?
    func markReconciled(runID: UUID) async throws
}

public protocol ConflictStore: Sendable {
    func openConflicts(for syncSetID: UUID) async throws -> [ConflictDecision]
    func resolvedConflicts(for syncSetID: UUID) async throws -> [ConflictResolutionRecord]
    func upsert(_ conflicts: [ConflictDecision]) async throws
    func resolve(_ id: UUID, as resolution: Resolution, at date: Date) async throws
}

public protocol AdviceCacheStore: Sendable {
    func cachedAdvice(forKey key: String) async -> ConflictAdvice?
    func store(_ advice: ConflictAdvice, forKey key: String) async
}

public protocol LocationRegistry: Sendable {
    func allLocations() async throws -> [SyncLocation]
    func upsert(_ location: SyncLocation) async throws
    func remove(_ id: LocationID, referencedBy: Set<UUID>) async throws
}

public protocol ActivityStore: Sendable {
    func append(_ entry: ActivityEntry) async
    func entries(matching query: ActivityQuery) async -> [ActivityEntry]
    func prune(olderThan date: Date, keepingCategories: Set<ActivityCategory>) async
}

public typealias Resolution = ConflictDecision.Resolution

public struct BaseRecordSelector: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var recordID: UUID?
    public var path: SyncPath?

    public init(syncSetID: UUID, recordID: UUID? = nil, path: SyncPath? = nil) {
        self.syncSetID = syncSetID
        self.recordID = recordID
        self.path = path
    }

    func matches(_ record: BaseRecord) -> Bool {
        guard record.syncSetID == syncSetID else { return false }
        if let recordID {
            return record.id == recordID
        }
        if let path {
            return record.path == path
        }
        return false
    }
}

public struct BaseRecordUpdate: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case upsert(BaseRecord)
        case tombstone(selector: BaseRecordSelector, deletedAt: Date, initiatedBy: LocationID?)
        case purge(BaseRecordSelector)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static func upsert(_ record: BaseRecord) -> BaseRecordUpdate {
        BaseRecordUpdate(kind: .upsert(record))
    }

    public static func tombstone(
        syncSetID: UUID,
        recordID: UUID,
        deletedAt: Date,
        initiatedBy: LocationID? = nil
    ) -> BaseRecordUpdate {
        BaseRecordUpdate(
            kind: .tombstone(
                selector: BaseRecordSelector(syncSetID: syncSetID, recordID: recordID),
                deletedAt: deletedAt,
                initiatedBy: initiatedBy
            )
        )
    }

    public static func tombstone(
        syncSetID: UUID,
        path: SyncPath,
        deletedAt: Date,
        initiatedBy: LocationID? = nil
    ) -> BaseRecordUpdate {
        BaseRecordUpdate(
            kind: .tombstone(
                selector: BaseRecordSelector(syncSetID: syncSetID, path: path),
                deletedAt: deletedAt,
                initiatedBy: initiatedBy
            )
        )
    }

    public static func purge(syncSetID: UUID, recordID: UUID) -> BaseRecordUpdate {
        BaseRecordUpdate(kind: .purge(BaseRecordSelector(syncSetID: syncSetID, recordID: recordID)))
    }

    public static func purge(syncSetID: UUID, path: SyncPath) -> BaseRecordUpdate {
        BaseRecordUpdate(kind: .purge(BaseRecordSelector(syncSetID: syncSetID, path: path)))
    }
}

public enum BaseRecordStoreError: Error, Equatable, Sendable {
    case corrupt(syncSetID: UUID)
    case recordNotFound(BaseRecordSelector)
    case io(detail: String)
}

public enum RunJournalStoreError: Error, Equatable, Sendable {
    case runAlreadyExists(UUID)
    case missingRun(UUID)
    case runAlreadyReconciled(UUID)
    case resultWithoutIntent(runID: UUID, operationID: OperationID)
    case corrupt(runID: UUID)
    case io(detail: String)
}

public enum LocationRegistryError: Error, Equatable, Sendable {
    case referenced(locationID: LocationID, syncSetIDs: Set<UUID>)
    case missing(LocationID)
}

public enum ConflictStoreError: Error, Equatable, Sendable {
    case missing(UUID)
}

public struct ConflictResolutionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var conflict: ConflictDecision
    public var resolution: Resolution
    public var resolvedAt: Date

    public init(id: UUID, conflict: ConflictDecision, resolution: Resolution, resolvedAt: Date) {
        self.id = id
        self.conflict = conflict
        self.resolution = resolution
        self.resolvedAt = resolvedAt
    }
}

public enum JournalOperationResultOutcome: String, Codable, Hashable, Sendable {
    case applied
    case skippedAlreadySatisfied
    case failed
}

public enum JournalRunOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
    case stoppedForReplan
    case cancelled
}

public enum JournalEvent: Codable, Hashable, Sendable {
    case intent(Operation)
    case result(operationID: OperationID, outcome: JournalOperationResultOutcome, occurredAt: Date, detail: String?)
    case itemConverged(decisionID: UUID, record: BaseRecord)
    case runFinished(outcome: JournalRunOutcome, occurredAt: Date, detail: String?)

    public var intentOperationID: OperationID? {
        guard case let .intent(operation) = self else { return nil }
        return operation.id
    }

    public var resultOperationID: OperationID? {
        guard case let .result(operationID, _, _, _) = self else { return nil }
        return operationID
    }

    public var isRunFinished: Bool {
        if case .runFinished = self {
            return true
        }
        return false
    }
}

public struct JournalReplay: Codable, Hashable, Sendable {
    public var runID: UUID
    public var syncSetID: UUID
    public var fingerprint: PlanFingerprint
    public var events: [JournalEvent]

    public init(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint, events: [JournalEvent]) {
        self.runID = runID
        self.syncSetID = syncSetID
        self.fingerprint = fingerprint
        self.events = events
    }

    public var intendedOperationIDs: Set<OperationID> {
        Set(events.compactMap(\.intentOperationID))
    }

    public var resultOperationIDs: Set<OperationID> {
        Set(events.compactMap(\.resultOperationID))
    }

    public var pendingOperationIDs: Set<OperationID> {
        intendedOperationIDs.subtracting(resultOperationIDs)
    }
}

public actor InMemoryBaseRecordStore: BaseRecordStore {
    private var recordsBySyncSet: [UUID: [BaseRecord]] = [:]

    public init(records: [BaseRecord] = []) {
        for record in records {
            recordsBySyncSet[record.syncSetID, default: []].append(record)
        }
        for key in recordsBySyncSet.keys {
            recordsBySyncSet[key] = sorted(recordsBySyncSet[key] ?? [])
        }
    }

    public func records(for syncSetID: UUID) async throws -> [BaseRecord] {
        sorted(recordsBySyncSet[syncSetID] ?? [])
    }

    public func apply(_ update: BaseRecordUpdate) async throws {
        try apply(update, to: &recordsBySyncSet)
    }

    private func apply(_ update: BaseRecordUpdate, to storage: inout [UUID: [BaseRecord]]) throws {
        switch update.kind {
        case let .upsert(record):
            var records = storage[record.syncSetID] ?? []
            records.removeAll { existing in
                existing.id == record.id || existing.path == record.path
            }
            records.append(record)
            storage[record.syncSetID] = sorted(records)

        case let .tombstone(selector, deletedAt, initiatedBy):
            var records = storage[selector.syncSetID] ?? []
            guard let index = records.firstIndex(where: selector.matches) else {
                throw BaseRecordStoreError.recordNotFound(selector)
            }
            records[index].tombstone = Tombstone(deletedAt: deletedAt, initiatedBy: initiatedBy)
            records[index].updatedAt = deletedAt
            storage[selector.syncSetID] = sorted(records)

        case let .purge(selector):
            var records = storage[selector.syncSetID] ?? []
            let originalCount = records.count
            records.removeAll(where: selector.matches)
            guard records.count != originalCount else {
                throw BaseRecordStoreError.recordNotFound(selector)
            }
            storage[selector.syncSetID] = sorted(records)
        }
    }

}

public actor InMemoryRunJournalStore: RunJournalStore {
    private var runs: [UUID: InMemoryJournalRun] = [:]

    public init() {}

    public func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws {
        guard runs[runID] == nil else {
            throw RunJournalStoreError.runAlreadyExists(runID)
        }
        runs[runID] = InMemoryJournalRun(
            syncSetID: syncSetID,
            fingerprint: fingerprint,
            events: [],
            isReconciled: false
        )
    }

    public func append(_ event: JournalEvent, runID: UUID) async throws {
        guard var run = runs[runID] else {
            throw RunJournalStoreError.missingRun(runID)
        }
        guard !run.isReconciled else {
            throw RunJournalStoreError.runAlreadyReconciled(runID)
        }
        try validate(event, runID: runID, existingEvents: run.events)
        run.events.append(event)
        runs[runID] = run
    }

    public func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay? {
        runs
            .filter { !$0.value.isReconciled && $0.value.syncSetID == syncSetID && !$0.value.events.contains(where: \.isRunFinished) }
            .map { runID, run in
                JournalReplay(runID: runID, syncSetID: run.syncSetID, fingerprint: run.fingerprint, events: run.events)
            }
            .sorted { $0.runID.uuidString < $1.runID.uuidString }
            .first
    }

    public func markReconciled(runID: UUID) async throws {
        guard var run = runs[runID] else {
            throw RunJournalStoreError.missingRun(runID)
        }
        run.isReconciled = true
        runs[runID] = run
    }
}

public actor InMemoryConflictStore: ConflictStore {
    private var open: [UUID: ConflictDecision] = [:]
    private var resolved: [UUID: ConflictResolutionRecord] = [:]

    public init(conflicts: [ConflictDecision] = []) {
        for conflict in conflicts {
            open[conflict.id] = conflict
        }
    }

    public func openConflicts(for syncSetID: UUID) async throws -> [ConflictDecision] {
        open.values
            .filter { $0.syncSetID == nil || $0.syncSetID == syncSetID }
            .sorted { $0.path == $1.path ? $0.id.uuidString < $1.id.uuidString : $0.path < $1.path }
    }

    public func resolvedConflicts(for syncSetID: UUID) async throws -> [ConflictResolutionRecord] {
        resolved.values
            .filter { $0.conflict.syncSetID == nil || $0.conflict.syncSetID == syncSetID }
            .sorted { $0.conflict.path == $1.conflict.path ? $0.id.uuidString < $1.id.uuidString : $0.conflict.path < $1.conflict.path }
    }

    public func upsert(_ conflicts: [ConflictDecision]) async throws {
        for conflict in conflicts {
            open[conflict.id] = conflict
        }
    }

    public func resolve(_ id: UUID, as resolution: Resolution, at date: Date) async throws {
        guard let conflict = open.removeValue(forKey: id) else {
            throw ConflictStoreError.missing(id)
        }
        resolved[id] = ConflictResolutionRecord(id: id, conflict: conflict, resolution: resolution, resolvedAt: date)
    }
}

public actor InMemoryAdviceCacheStore: AdviceCacheStore {
    private var cache: [String: ConflictAdvice] = [:]

    public init() {}

    public func cachedAdvice(forKey key: String) async -> ConflictAdvice? {
        cache[key]
    }

    public func store(_ advice: ConflictAdvice, forKey key: String) async {
        cache[key] = advice
    }
}

public actor InMemoryLocationRegistry: LocationRegistry {
    private var locations: [LocationID: SyncLocation] = [:]

    public init(locations: [SyncLocation] = []) {
        for location in locations {
            self.locations[location.id] = location
        }
    }

    public func allLocations() async throws -> [SyncLocation] {
        locations.values.sorted { $0.id < $1.id }
    }

    public func upsert(_ location: SyncLocation) async throws {
        locations[location.id] = location
    }

    public func remove(_ id: LocationID, referencedBy: Set<UUID>) async throws {
        guard referencedBy.isEmpty else {
            throw LocationRegistryError.referenced(locationID: id, syncSetIDs: referencedBy)
        }
        guard locations.removeValue(forKey: id) != nil else {
            throw LocationRegistryError.missing(id)
        }
    }
}

public actor InMemoryActivityStore: ActivityStore {
    private var entries: [ActivityEntry] = []
    private let capacity: Int

    public init(entries: [ActivityEntry] = [], capacity: Int = 10_000) {
        self.entries = entries.sorted(by: activityNewestFirst)
        self.capacity = capacity
        if self.entries.count > capacity {
            self.entries.removeLast(self.entries.count - capacity)
        }
    }

    public func append(_ entry: ActivityEntry) async {
        entries.append(entry)
        entries.sort(by: activityNewestFirst)
        trimToCapacity()
    }

    public func entries(matching query: ActivityQuery = ActivityQuery()) async -> [ActivityEntry] {
        filterActivity(entries, query: query)
    }

    public func prune(olderThan date: Date, keepingCategories: Set<ActivityCategory> = []) async {
        entries.removeAll { entry in
            entry.occurredAt < date && !keepingCategories.contains(entry.category)
        }
    }

    public func prune(using policy: ActivityRetentionPolicy, now: Date) async {
        entries.removeAll { entry in
            entry.occurredAt < policy.cutoffDate(for: entry.category, now: now)
        }
    }

    private func trimToCapacity() {
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

public actor FileBaseRecordStore: BaseRecordStore {
    private let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func records(for syncSetID: UUID) async throws -> [BaseRecord] {
        let fileURL = recordsURL(for: syncSetID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try CanonicalCoding.decoder().decode(BaseRecordsEnvelope.self, from: data)
            return sorted(envelope.records.filter { $0.syncSetID == syncSetID })
        } catch {
            quarantine(fileURL)
            throw BaseRecordStoreError.corrupt(syncSetID: syncSetID)
        }
    }

    public func apply(_ update: BaseRecordUpdate) async throws {
        let syncSetID = update.syncSetID
        let existing = try await records(for: syncSetID)
        var recordsBySyncSet = [syncSetID: existing]
        try InMemoryBaseRecordStore.applyForFile(update, to: &recordsBySyncSet)
        try write(recordsBySyncSet[syncSetID] ?? [], for: syncSetID)
    }

    private func write(_ records: [BaseRecord], for syncSetID: UUID) throws {
        let data = try CanonicalCoding.encoder().encode(
            BaseRecordsEnvelope(schemaVersion: 1, records: sorted(records))
        )
        do {
            try data.write(to: recordsURL(for: syncSetID), options: .atomic)
        } catch {
            throw BaseRecordStoreError.io(detail: String(describing: error))
        }
    }

    private func recordsURL(for syncSetID: UUID) -> URL {
        rootURL.appendingPathComponent("records-\(syncSetID.uuidString).json", isDirectory: false)
    }

    private func quarantine(_ fileURL: URL) {
        let timestamp = CanonicalCoding.dateString(Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        var destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)", isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)-\(UUID().uuidString)", isDirectory: false)
        }
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }
}

public actor FileRunJournalStore: RunJournalStore {
    private let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws {
        let fileURL = journalURL(for: runID)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RunJournalStoreError.runAlreadyExists(runID)
        }
        let line = JournalLine(
            schemaVersion: 1,
            entry: .begin(JournalBeginLine(runID: runID, syncSetID: syncSetID, fingerprint: fingerprint))
        )
        try appendLine(line, to: fileURL)
    }

    public func append(_ event: JournalEvent, runID: UUID) async throws {
        let state = try replayFile(runID: runID)
        guard !state.isReconciled else {
            throw RunJournalStoreError.runAlreadyReconciled(runID)
        }
        try validate(event, runID: runID, existingEvents: state.events)
        try appendLine(JournalLine(schemaVersion: 1, entry: .event(event)), to: journalURL(for: runID))
    }

    public func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay? {
        try journalURLs()
            .compactMap { fileURL -> JournalReplay? in
                let runID = try runIDFromJournalURL(fileURL)
                let state = try replayFile(runID: runID)
                guard !state.isReconciled, state.syncSetID == syncSetID, !state.events.contains(where: \.isRunFinished) else { return nil }
                return JournalReplay(
                    runID: runID,
                    syncSetID: state.syncSetID,
                    fingerprint: state.fingerprint,
                    events: state.events
                )
            }
            .sorted { $0.runID.uuidString < $1.runID.uuidString }
            .first
    }

    public func markReconciled(runID: UUID) async throws {
        let state = try replayFile(runID: runID)
        let line = JournalLine(
            schemaVersion: 1,
            entry: .reconciled(
                JournalReconciledLine(
                    runID: runID,
                    syncSetID: state.syncSetID,
                    fingerprint: state.fingerprint,
                    reconciledAt: Date()
                )
            )
        )
        do {
            let data = try jsonLineData(line)
            try data.write(to: journalURL(for: runID), options: .atomic)
        } catch let error as RunJournalStoreError {
            throw error
        } catch {
            throw RunJournalStoreError.io(detail: String(describing: error))
        }
    }

    private func appendLine(_ line: JournalLine, to fileURL: URL) throws {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(try jsonLineData(line))
            handle.synchronizeFile()
        } catch let error as RunJournalStoreError {
            throw error
        } catch {
            throw RunJournalStoreError.io(detail: String(describing: error))
        }
    }

    private func replayFile(runID: UUID) throws -> JournalFileState {
        let fileURL = journalURL(for: runID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RunJournalStoreError.missingRun(runID)
        }
        do {
            let lines = try jsonlLines(from: fileURL)
            var begin: JournalBeginLine?
            var events: [JournalEvent] = []
            var reconciled: JournalReconciledLine?
            for line in lines {
                let decoded = try CanonicalCoding.decoder().decode(JournalLine.self, from: Data(line.utf8))
                switch decoded.entry {
                case let .begin(value):
                    begin = value
                case let .event(event):
                    events.append(event)
                case let .reconciled(value):
                    reconciled = value
                }
            }
            if let reconciled {
                return JournalFileState(
                    syncSetID: reconciled.syncSetID,
                    fingerprint: reconciled.fingerprint,
                    events: [],
                    isReconciled: true
                )
            }
            guard let begin else {
                throw RunJournalStoreError.corrupt(runID: runID)
            }
            return JournalFileState(
                syncSetID: begin.syncSetID,
                fingerprint: begin.fingerprint,
                events: events,
                isReconciled: false
            )
        } catch let error as RunJournalStoreError {
            throw error
        } catch {
            throw RunJournalStoreError.corrupt(runID: runID)
        }
    }

    private func journalURL(for runID: UUID) -> URL {
        rootURL.appendingPathComponent("journal-\(runID.uuidString).jsonl", isDirectory: false)
    }

    private func journalURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("journal-") && $0.pathExtension == "jsonl" }
    }
}

public actor FileActivityStore: ActivityStore {
    private let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func append(_ entry: ActivityEntry) async {
        do {
            try appendLine(entry, to: activityURL(for: entry.occurredAt))
        } catch {
            preconditionFailure("Activity store failed to append entry: \(error)")
        }
    }

    public func entries(matching query: ActivityQuery = ActivityQuery()) async -> [ActivityEntry] {
        do {
            let entries = try activityURLs().flatMap { try readEntries(from: $0) }
            return filterActivity(entries, query: query)
        } catch {
            preconditionFailure("Activity store failed to read entries: \(error)")
        }
    }

    public func prune(olderThan date: Date, keepingCategories: Set<ActivityCategory> = []) async {
        do {
            for fileURL in try activityURLs() {
                let kept = try readEntries(from: fileURL).filter { entry in
                    entry.occurredAt >= date || keepingCategories.contains(entry.category)
                }
                try writeEntries(kept, to: fileURL)
            }
        } catch {
            preconditionFailure("Activity store failed to prune entries: \(error)")
        }
    }

    public func prune(using policy: ActivityRetentionPolicy, now: Date) async {
        do {
            for fileURL in try activityURLs() {
                let kept = try readEntries(from: fileURL).filter { entry in
                    entry.occurredAt >= policy.cutoffDate(for: entry.category, now: now)
                }
                try writeEntries(kept, to: fileURL)
            }
        } catch {
            preconditionFailure("Activity store failed to prune entries: \(error)")
        }
    }

    private func appendLine(_ entry: ActivityEntry, to fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(try jsonLineData(entry))
        handle.synchronizeFile()
    }

    private func readEntries(from fileURL: URL) throws -> [ActivityEntry] {
        try jsonlLines(from: fileURL).map { line in
            try CanonicalCoding.decoder().decode(ActivityEntry.self, from: Data(line.utf8))
        }
    }

    private func writeEntries(_ entries: [ActivityEntry], to fileURL: URL) throws {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let data = try entries
            .sorted(by: activityNewestFirst)
            .map(jsonLineData)
            .reduce(into: Data()) { partial, line in
                partial.append(line)
            }
        try data.write(to: fileURL, options: .atomic)
    }

    private func activityURL(for date: Date) -> URL {
        rootURL.appendingPathComponent("activity-\(activityMonthKey(for: date)).jsonl", isDirectory: false)
    }

    private func activityURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("activity-") && $0.pathExtension == "jsonl" }
    }
}

extension SyncPlanner {
    public func plan(
        syncSet: SyncSet,
        locations: [SyncLocation] = [],
        snapshots: [LocationSnapshot],
        settings: SyncSettings? = nil,
        baseRecordStore: any BaseRecordStore,
        environment: PlanningEnvironment
    ) async -> PlanOutcome {
        do {
            let records = try await baseRecordStore.records(for: syncSet.id)
            return plan(
                SyncPlanningInput(
                    syncSet: syncSet,
                    locations: locations,
                    records: records,
                    snapshots: snapshots,
                    settings: settings,
                    baseStateUnreadableDetail: nil
                ),
                environment: environment
            )
        } catch {
            return plan(
                SyncPlanningInput(
                    syncSet: syncSet,
                    locations: locations,
                    records: [],
                    snapshots: snapshots,
                    settings: settings,
                    baseStateUnreadableDetail: baseStateUnreadableDetail(syncSetID: syncSet.id, error: error)
                ),
                environment: environment
            )
        }
    }
}

private struct InMemoryJournalRun: Sendable {
    var syncSetID: UUID
    var fingerprint: PlanFingerprint
    var events: [JournalEvent]
    var isReconciled: Bool
}

private struct BaseRecordsEnvelope: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var records: [BaseRecord]
}

private struct JournalLine: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var entry: JournalLineEntry
}

private enum JournalLineEntry: Codable, Hashable, Sendable {
    case begin(JournalBeginLine)
    case event(JournalEvent)
    case reconciled(JournalReconciledLine)
}

private struct JournalBeginLine: Codable, Hashable, Sendable {
    var runID: UUID
    var syncSetID: UUID
    var fingerprint: PlanFingerprint
}

private struct JournalReconciledLine: Codable, Hashable, Sendable {
    var runID: UUID
    var syncSetID: UUID
    var fingerprint: PlanFingerprint
    var reconciledAt: Date
}

private struct JournalFileState: Sendable {
    var syncSetID: UUID
    var fingerprint: PlanFingerprint
    var events: [JournalEvent]
    var isReconciled: Bool
}

private extension BaseRecordUpdate {
    var syncSetID: UUID {
        switch kind {
        case let .upsert(record):
            return record.syncSetID
        case let .tombstone(selector, _, _), let .purge(selector):
            return selector.syncSetID
        }
    }
}

private extension InMemoryBaseRecordStore {
    static func applyForFile(_ update: BaseRecordUpdate, to storage: inout [UUID: [BaseRecord]]) throws {
        switch update.kind {
        case let .upsert(record):
            var records = storage[record.syncSetID] ?? []
            records.removeAll { existing in
                existing.id == record.id || existing.path == record.path
            }
            records.append(record)
            storage[record.syncSetID] = sorted(records)

        case let .tombstone(selector, deletedAt, initiatedBy):
            var records = storage[selector.syncSetID] ?? []
            guard let index = records.firstIndex(where: selector.matches) else {
                throw BaseRecordStoreError.recordNotFound(selector)
            }
            records[index].tombstone = Tombstone(deletedAt: deletedAt, initiatedBy: initiatedBy)
            records[index].updatedAt = deletedAt
            storage[selector.syncSetID] = sorted(records)

        case let .purge(selector):
            var records = storage[selector.syncSetID] ?? []
            let originalCount = records.count
            records.removeAll(where: selector.matches)
            guard records.count != originalCount else {
                throw BaseRecordStoreError.recordNotFound(selector)
            }
            storage[selector.syncSetID] = sorted(records)
        }
    }
}

private func validate(_ event: JournalEvent, runID: UUID, existingEvents: [JournalEvent]) throws {
    guard let operationID = event.resultOperationID else { return }
    let hasIntent = existingEvents.contains { $0.intentOperationID == operationID }
    if !hasIntent {
        throw RunJournalStoreError.resultWithoutIntent(runID: runID, operationID: operationID)
    }
}

private func sorted(_ records: [BaseRecord]) -> [BaseRecord] {
    records.sorted { lhs, rhs in
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private func activityNewestFirst(_ lhs: ActivityEntry, _ rhs: ActivityEntry) -> Bool {
    if lhs.occurredAt != rhs.occurredAt {
        return lhs.occurredAt > rhs.occurredAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func filterActivity(_ entries: [ActivityEntry], query: ActivityQuery) -> [ActivityEntry] {
    entries
        .sorted(by: activityNewestFirst)
        .filter { entry in
            if let syncSetID = query.syncSetID, entry.syncSetID != syncSetID {
                return false
            }
            if let runID = query.runID, entry.runID != runID {
                return false
            }
            if let categories = query.categories, !categories.contains(entry.category) {
                return false
            }
            if let pathPrefix = query.pathPrefix {
                guard let path = entry.path, path.isDescendant(of: pathPrefix) else {
                    return false
                }
            }
            if let dateRange = query.dateRange, !dateRange.contains(entry.occurredAt) {
                return false
            }
            return true
        }
        .prefix(max(query.limit, 0))
        .map { $0 }
}

private func jsonLineData<T: Encodable>(_ value: T) throws -> Data {
    var data = try CanonicalCoding.encoder().encode(value)
    data.append(0x0A)
    return data
}

private func jsonlLines(from fileURL: URL) throws -> [String] {
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [] }
    let text = String(decoding: data, as: UTF8.self)
    var lines = text.components(separatedBy: "\n")
    if text.hasSuffix("\n") {
        lines.removeLast()
    } else {
        lines.removeLast()
    }
    return lines.filter { !$0.isEmpty }
}

private func activityMonthKey(for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let components = calendar.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
}

private func runIDFromJournalURL(_ fileURL: URL) throws -> UUID {
    let filename = fileURL.deletingPathExtension().lastPathComponent
    let prefix = "journal-"
    guard filename.hasPrefix(prefix),
          let runID = UUID(uuidString: String(filename.dropFirst(prefix.count))) else {
        throw RunJournalStoreError.io(detail: "Invalid journal filename \(fileURL.lastPathComponent)")
    }
    return runID
}

private func baseStateUnreadableDetail(syncSetID: UUID, error: Error) -> String {
    if case let BaseRecordStoreError.corrupt(corruptSyncSetID) = error {
        return "Base records for \(corruptSyncSetID.uuidString) are unreadable."
    }
    return "Base records for \(syncSetID.uuidString) could not be read: \(error)."
}
