import AetherloomCore
import Foundation

public enum StatusTone: Sendable, Hashable {
    case healthy
    case attention
    case paused
    case neutral
}

public func tone(for availability: LocationAvailability) -> StatusTone {
    switch availability {
    case .available:
        return .healthy
    case let .unavailable(reason):
        switch reason {
        case .volumeNotMounted:
            return .neutral
        case .notAuthenticated,
             .networkUnreachable,
             .volumeUnreachable,
             .scopeMissing,
             .rateLimited,
             .unknown:
            return .paused
        }
    }
}

public func tone(for state: SyncSetState) -> StatusTone {
    if state.isPaused || state.lastPreparation?.refusals.isEmpty == false {
        return .paused
    }
    if state.lastPreparation?.holds.isEmpty == false || state.openConflictCount > 0 {
        return .attention
    }
    if state.phase != .idle || (state.lastRun == nil && state.lastPreparation == nil) {
        return .neutral
    }
    return .healthy
}

public struct StatusLine: Sendable, Hashable {
    public var text: String
    public var tone: StatusTone
    public var safetyNote: String?

    public init(text: String, tone: StatusTone, safetyNote: String? = nil) {
        self.text = text
        self.tone = tone
        self.safetyNote = safetyNote
    }
}

public func statusLine(for state: SyncSetState, now: Date) -> StatusLine {
    _ = now
    if state.isPaused {
        return StatusLine(text: "Paused by you", tone: .paused)
    }
    if let refusal = state.lastPreparation?.refusals.first {
        return StatusLine(text: "Paused for safety", tone: .paused, safetyNote: refusal.message)
    }
    if let hold = state.lastPreparation?.holds.first {
        return StatusLine(text: "Needs review", tone: .attention, safetyNote: hold.message)
    }
    if state.openConflictCount > 0 {
        return StatusLine(
            text: "Needs review",
            tone: .attention,
            safetyNote: ActivityMessageCatalog.conflictPreserved
        )
    }
    switch state.phase {
    case .preparing:
        return StatusLine(text: "Preparing", tone: .neutral)
    case .executing:
        return StatusLine(text: "Syncing", tone: .neutral)
    case .idle:
        break
    }
    if state.lastRun == nil && state.lastPreparation == nil {
        return StatusLine(text: "Never synced", tone: .neutral)
    }
    return StatusLine(text: "Up to date", tone: .healthy)
}

public func statusLine(for location: LocationState, now: Date) -> StatusLine {
    _ = now
    switch location.availability {
    case .available:
        return StatusLine(text: "Up to date", tone: .healthy)
    case .unavailable(.volumeNotMounted):
        return StatusLine(
            text: "Waiting for volume",
            tone: .neutral,
            safetyNote: ActivityMessageCatalog.providerUnavailable
        )
    case .unavailable:
        return StatusLine(
            text: "Provider unavailable",
            tone: .paused,
            safetyNote: ActivityMessageCatalog.providerUnavailable
        )
    }
}

public func workspaceStatus(
    for states: [SyncSetState],
    openConflictCount: Int,
    activityEntries: [ActivityEntry] = []
) -> WorkspaceStatus {
    if let busy = states.first(where: { $0.phase != .idle }) {
        return .busy(stage: currentStage(for: busy, entries: activityEntries))
    }
    let holdCount = states.reduce(0) { $0 + ($1.lastPreparation?.holds.count ?? 0) }
    if holdCount + openConflictCount > 0 {
        return .needsReview(count: holdCount + openConflictCount)
    }
    if states.contains(where: { $0.lastPreparation?.refusals.isEmpty == false }) {
        return .pausedForSafety
    }
    return .allInSync
}

private func currentStage(for state: SyncSetState, entries: [ActivityEntry]) -> String {
    if let message = entries
        .filter({ $0.syncSetID == state.id })
        .sorted(by: { $0.occurredAt > $1.occurredAt })
        .first(where: {
            $0.message.hasSuffix(" started.") || $0.message.hasSuffix(" finished.")
        })?
        .message
    {
        if message.hasSuffix(" started.") {
            return String(message.dropLast(" started.".count))
        }
    }
    switch state.phase {
    case .preparing:
        return "Preparing"
    case .executing:
        return "Executing"
    case .idle:
        return ""
    }
}
