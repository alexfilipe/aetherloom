import AetherloomCore
import Foundation

final class EngineEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    func stream() -> AsyncStream<EngineEvent> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.withLock {
                continuations[subscriberID] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(subscriberID)
            }
        }
    }

    func emit(_ event: EngineEvent) {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current {
            continuation.yield(event)
        }
    }

    private func remove(_ subscriberID: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: subscriberID)
        }
    }
}

actor EventingActivityStore: ActivityStore {
    private let backing: any ActivityStore
    private let eventHub: EngineEventHub

    init(backing: any ActivityStore, eventHub: EngineEventHub) {
        self.backing = backing
        self.eventHub = eventHub
    }

    func append(_ entry: ActivityEntry) async {
        await backing.append(entry)
        eventHub.emit(.activityAppended(entry))
    }

    func entries(matching query: ActivityQuery) async -> [ActivityEntry] {
        await backing.entries(matching: query)
    }

    func prune(olderThan date: Date, keepingCategories: Set<ActivityCategory>) async {
        await backing.prune(olderThan: date, keepingCategories: keepingCategories)
    }
}
