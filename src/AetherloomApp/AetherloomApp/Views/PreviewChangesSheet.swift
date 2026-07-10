import AetherloomBridge
import AetherloomCore
import SwiftUI

struct PreviewChangesSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var preparation: SyncPreparation
    @State private var acknowledgedTrash = false
    @State private var acknowledgedConflicts = false
    @State private var isExecuting: Bool
    @State private var isRefreshing = false
    @State private var runSummary: SyncRunSummary?
    @FocusState private var approvalFocus: ApprovalFocus?

    init(
        preparation: SyncPreparation,
        initialState: PreviewSheetInitialState = .ready
    ) {
        _preparation = State(initialValue: preparation)
        switch initialState {
        case .ready:
            _isExecuting = State(initialValue: false)
            _runSummary = State(initialValue: nil)
        case .executing:
            _isExecuting = State(initialValue: true)
            _runSummary = State(initialValue: nil)
        case let .finished(summary):
            _isExecuting = State(initialValue: false)
            _runSummary = State(initialValue: summary)
        }
    }

    private var locations: [LocationState] {
        appModel.workspace?.locations ?? []
    }

    private var display: PreviewDisplay {
        previewDisplay(for: preparation, locations: locations)
    }

    private var isRefusal: Bool {
        preparation.preview.planFingerprint == nil
    }

    private var isEmptyPlan: Bool {
        !isRefusal && display.sections.isEmpty
    }

    private var isWaitingOnly: Bool {
        display.sections.count == 1 && display.sections.first?.kind == .waiting
    }

    private var anotherRunIsActive: Bool {
        !isExecuting && !isRefreshing && appModel.isBusy(syncSetID: preparation.preview.syncSetID)
    }

    private var allRequiredCountsAcknowledged: Bool {
        guard let requirement = display.approvalRequirement else { return true }
        let trashIsAcknowledged = requirement.trashCount == 0 || acknowledgedTrash
        let conflictsAreAcknowledged = requirement.conflictCount == 0 || acknowledgedConflicts
        return trashIsAcknowledged && conflictsAreAcknowledged
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 560, idealHeight: 560)
        .interactiveDismissDisabled(isExecuting)
        .onExitCommand {
            if !isExecuting {
                dismiss()
            }
        }
        .task {
            await Task.yield()
            if approvalFocus == nil {
                approvalFocus = initialApprovalFocus
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Theme.weave)

            VStack(alignment: .leading, spacing: 3) {
                Text(preparation.syncSetName)
                    .font(.title2.weight(.semibold))
                Text(display.headline)
                    .font(.subheadline.weight(.medium))
                Text("Generated \(DisplayFormatting.absoluteDate(preparation.preview.generatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .disabled(isExecuting)
            .accessibilityLabel("Close preview")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if anotherRunIsActive {
            alreadyRunningState
        } else if isRefusal {
            refusalState
        } else {
            planContent
        }
    }

    private var alreadyRunningState: some View {
        EmptyStateView(
            systemImage: "arrow.triangle.2.circlepath",
            title: "A sync is already running for this set",
            message: "Wait for the current run to finish before preparing another preview."
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refusalState: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(display.refusals) { refusal in
                    InlineBanner(
                        title: refusal.location?.displayName ?? "Paused for safety",
                        message: refusal.message,
                        detail: refusal.detail
                    )
                }

                EmptyStateView(
                    systemImage: "shield.lefthalf.filled",
                    title: "Nothing can sync until this clears",
                    message: "Nothing will be deleted while a provider is unreachable."
                )
            }
            .padding(20)
        }
    }

    private var planContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let drift = driftDetails {
                    driftBanner(drift)
                }

                ForEach(display.holds) { hold in
                    holdView(hold)
                }

                if isEmptyPlan {
                    EmptyStateView(
                        systemImage: "checkmark.seal.fill",
                        title: "Everything matches — nothing to sync.",
                        message: "Every location already has the same files."
                    )
                } else {
                    ForEach(display.sections) { section in
                        previewSection(section)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func holdView(_ hold: HoldDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if hold.isConflictHold {
                SafetyBanner(
                    title: hold.message,
                    message: hold.evidenceSummary ?? "Review the preserved versions before syncing.",
                    actionTitle: "Review conflicts"
                ) {
                    appModel.activeSheet = nil
                    appModel.show(.conflicts)
                }
            } else {
                SafetyBanner(
                    title: hold.message,
                    message: hold.evidenceSummary ?? "Review the affected changes before syncing."
                )
            }

            if let note = hold.advisoryNote {
                AdviceChip(
                    rationale: note,
                    attribution: hold.advisoryAttribution ?? "Generated on-device"
                )
            }
        }
        .focusable()
        .focused($approvalFocus, equals: .hold(hold.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs review. \(hold.message). \(hold.evidenceSummary ?? "Review the affected changes before syncing.")")
    }

    private func previewSection(_ section: SectionDisplay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: section.title,
                accessory: sectionAccessory(section)
            )
            .padding(.bottom, 8)

            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Divider()
                        .padding(.leading, 34)
                }
                previewRow(entry, kind: section.kind)
            }
        }
        .card(padding: 14, hoverLift: false)
        .focusable()
        .focused($approvalFocus, equals: .section(section.kind))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(DisplayFormatting.itemCount(section.entryCount))")
    }

    private func previewRow(_ entry: PreviewEntryDisplay, kind: PreviewSectionKind) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: kind.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(kind.tone.color)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                PathText(entry.path)
                Text(entry.summary)
                    .font(.subheadline)
                    .foregroundStyle(kind == .waiting ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let causality = entry.causality {
                    Text(causality)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let advice = advice(for: entry) {
                    AdviceChip(advice: advice)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                if let byteSize = entry.byteSize {
                    Text(DisplayFormatting.byteCount(byteSize))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    ForEach(entry.destinations) { destination in
                        ServiceMark(provider: destination.provider, size: 24)
                            .help(destination.displayName)
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var footer: some View {
        if isRefusal || anotherRunIsActive || isEmptyPlan {
            closeOnlyFooter
        } else if isWaitingOnly {
            HStack {
                Text("These files can sync after their content finishes downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sync Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        } else if isExecuting {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Applying \(DisplayFormatting.itemCount(display.totals.changeCount))…")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(20)
        } else {
            approvalFooter
        }
    }

    private var closeOnlyFooter: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var approvalFooter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let stale = previewIsStale(at: context.date)
            VStack(alignment: .leading, spacing: 11) {
                if let requirement = display.approvalRequirement {
                    if requirement.trashCount > 0 {
                        CountAcknowledgeRow(
                            kind: .trash,
                            count: requirement.trashCount,
                            isAcknowledged: $acknowledgedTrash
                        )
                        .focused($approvalFocus, equals: .trashAcknowledgment)
                    }
                    if requirement.conflictCount > 0 {
                        CountAcknowledgeRow(
                            kind: .conflicts,
                            count: requirement.conflictCount,
                            isAcknowledged: $acknowledgedConflicts
                        )
                        .focused($approvalFocus, equals: .conflictAcknowledgment)
                    }

                    if stale {
                        Label("This preview is stale — preview again", systemImage: "clock.badge.exclamationmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Approval window: 15 minutes · Preview freshness: \(freshnessCountdown(at: context.date))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .liveNumericTransition()
                    }
                }

                HStack {
                    if stale {
                        Button {
                            Task { await refreshPreview() }
                        } label: {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Refresh Preview", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshing)
                    }

                    Spacer()

                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .focused($approvalFocus, equals: .cancel)

                    if !stale && driftDetails == nil {
                        Button {
                            Task { await execute() }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!allRequiredCountsAcknowledged)
                        .accessibilityLabel("Sync Now")
                        .accessibilityHint("Press Command Return to approve and sync")
                        .focused($approvalFocus, equals: .approve)
                    }
                }
            }
            .padding(20)
        }
    }

    private func execute() async {
        guard !isExecuting, !isWaitingOnly, !isRefusal else { return }
        let approval: PlanApproval?
        if let requirement = display.approvalRequirement {
            guard allRequiredCountsAcknowledged else { return }
            approval = makeApproval(requirement, at: Date())
        } else {
            approval = nil
        }

        isExecuting = true
        let summary = await appModel.executePreview(preparation, approval: approval)
        isExecuting = false
        guard let summary else { return }

        switch summary.outcome {
        case .stoppedForReplan:
            runSummary = summary
        default:
            appModel.finishPreview(with: summary)
        }
    }

    private func refreshPreview() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let refreshed = await appModel.refreshPreview(syncSetID: preparation.preview.syncSetID) else {
            return
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
            preparation = refreshed
            acknowledgedTrash = false
            acknowledgedConflicts = false
            runSummary = nil
        }
    }

    private var driftDetails: (location: LocationID, path: SyncPath)? {
        guard let runSummary,
              case let .stoppedForReplan(location, path) = runSummary.outcome
        else {
            return nil
        }
        return (location, path)
    }

    private func driftBanner(_ drift: (location: LocationID, path: SyncPath)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineBanner(
                title: "Files changed while you were reviewing",
                message: "Nothing was applied to \(drift.path.rawValue). Preview again to see the current plan.",
                detail: "The change was detected at \(locationName(drift.location))."
            )
            Button {
                Task { await refreshPreview() }
            } label: {
                Label("Refresh Preview", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
        }
    }

    private func advice(for entry: PreviewEntryDisplay) -> AdviceDisplay? {
        guard let conflict = preparation.preview.conflicts.first(where: { $0.path == entry.path }) else {
            return nil
        }
        let advice = preparation.advice.first(where: { $0.conflictID == conflict.id })
            ?? preparation.preview.advice.first(where: { $0.conflictID == conflict.id })
        return conflictDisplay(
            for: conflict,
            advice: advice,
            locations: locations,
            plan: preparation.outcome.planValue
        ).advice
    }

    private func sectionAccessory(_ section: SectionDisplay) -> String {
        let count = DisplayFormatting.itemCount(section.entryCount)
        let bytes = section.entries.compactMap(\.byteSize).reduce(0, +)
        return bytes > 0 ? "\(count) · \(DisplayFormatting.byteCount(bytes))" : count
    }

    private func locationName(_ locationID: LocationID) -> String {
        locations.first(where: { $0.id == locationID })?.location.displayName ?? locationID.displayName
    }

    private func previewIsStale(at date: Date) -> Bool {
        display.approvalRequirement != nil
            && date >= preparation.preview.generatedAt.addingTimeInterval(15 * 60)
    }

    private func freshnessCountdown(at date: Date) -> String {
        let remaining = max(
            0,
            Int(preparation.preview.generatedAt.addingTimeInterval(15 * 60).timeIntervalSince(date))
        )
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private var initialApprovalFocus: ApprovalFocus {
        if let hold = display.holds.first {
            return .hold(hold.id)
        }
        if let section = display.sections.first {
            return .section(section.kind)
        }
        if display.approvalRequirement?.trashCount ?? 0 > 0 {
            return .trashAcknowledgment
        }
        if display.approvalRequirement?.conflictCount ?? 0 > 0 {
            return .conflictAcknowledgment
        }
        return .cancel
    }
}

private enum ApprovalFocus: Hashable {
    case hold(UUID)
    case section(PreviewSectionKind)
    case trashAcknowledgment
    case conflictAcknowledgment
    case cancel
    case approve
}

enum PreviewSheetInitialState {
    case ready
    case executing
    case finished(SyncRunSummary)
}

private extension HoldDisplay {
    var isConflictHold: Bool {
        if case .conflicts = reason { return true }
        return false
    }
}

private extension PreviewSectionKind {
    var symbolName: String {
        switch self {
        case .additions: "plus.circle.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .movesAndRenames: "arrow.right.circle.fill"
        case .waiting: "icloud.and.arrow.down"
        case .movesToTrash: "trash"
        case .bothVersionsPreserved: "doc.on.doc"
        }
    }

    var tone: Tone {
        switch self {
        case .waiting: .neutral
        case .movesToTrash, .bothVersionsPreserved: .attention
        case .additions, .updates, .movesAndRenames: .healthy
        }
    }
}

#Preview("Clear plan") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.clear)
}

#Preview("Gated plan") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.gated)
}

#Preview("Refusal") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.refusal)
}

#Preview("Empty") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.empty)
}

#Preview("Executing") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.gated, state: .executing)
}

#Preview("Drift") {
    PreviewSheetFixture.view(preparation: PreviewSheetFixture.gated, state: .finished(.drift))
}

@MainActor
private enum PreviewSheetFixture {
    private static let now = Date().addingTimeInterval(-60)
    private static let syncSetID = UUID(uuidString: "60000000-0000-0000-0000-000000000001") ?? UUID()
    private static let runID = UUID(uuidString: "60000000-0000-0000-0000-000000000002") ?? UUID()
    private static let fingerprint = PlanFingerprint(rawValue: "preview-sheet-fixture")

    static let clear = preparation(headline: "6 changes ready to sync", sections: populatedSections, gate: .clear)
    static let gated = preparation(
        headline: "Needs review",
        holds: [
            HoldNotice(
                id: id(30),
                reason: .deletionsNeedReview(count: 1),
                message: HoldReason.deletionsNeedReview(count: 1).message
            ),
            HoldNotice(
                id: id(31),
                reason: .conflicts(count: 1),
                message: HoldReason.conflicts(count: 1).message
            ),
        ],
        sections: populatedSections,
        gate: .hold([.deletionsNeedReview(count: 1), .conflicts(count: 1)]),
        includeApprovalCounts: true
    )
    static let empty = preparation(headline: "0 changes ready to sync", sections: [], gate: .clear)
    static let refusal: SyncPreparation = {
        let reason = RefusalReason.locationUnavailable(
            .nasFolder,
            .volumeNotMounted(detail: "NAS \"Tank\" is not mounted.")
        )
        let preview = ChangePreview(
            syncSetID: syncSetID,
            planFingerprint: nil,
            headline: "Paused for safety",
            refusals: [
                RefusalNotice(
                    id: id(40),
                    reason: reason,
                    locationID: .nasFolder,
                    message: reason.message,
                    detail: "NAS \"Tank\": NAS \"Tank\" is not mounted."
                ),
            ],
            generatedAt: now
        )
        return SyncPreparation(
            outcome: .refusal(SyncRefusal(syncSetID: syncSetID, reasons: [reason], occurredAt: now)),
            preview: preview,
            runID: runID,
            syncSetName: "Photos Archive"
        )
    }()

    static func view(
        preparation: SyncPreparation,
        state: PreviewSheetInitialState = .ready
    ) -> some View {
        let world = DemoWorld.standard
        let locations = world.locations.map {
            LocationState(location: $0, availability: .available, lastCheckedAt: now)
        }
        let snapshot = WorkspaceSnapshot(
            locations: locations,
            syncSets: [],
            openConflictCount: 1,
            status: .needsReview(count: 1)
        )
        let model = AppModel(
            session: PreviewEngineSession(snapshot: snapshot),
            bootstrapImmediately: false,
            initialWorkspace: snapshot,
            initialPhase: .ready
        )
        return PreviewChangesSheet(preparation: preparation, initialState: state)
            .environmentObject(model)
            .tint(Theme.accent)
    }

    private static func preparation(
        headline: String,
        holds: [HoldNotice] = [],
        sections: [PreviewSection],
        gate: ExecutionGate,
        includeApprovalCounts: Bool = false
    ) -> SyncPreparation {
        let approvalValues = includeApprovalCounts ? approvalPlanValues : ([], OperationSchedule(), [])
        let plan = SyncPlan(
            syncSetID: syncSetID,
            generatedAt: now,
            decisions: approvalValues.0,
            schedule: approvalValues.1,
            conflicts: approvalValues.2,
            gate: gate,
            fingerprint: fingerprint
        )
        let preview = ChangePreview(
            syncSetID: syncSetID,
            planFingerprint: fingerprint,
            headline: headline,
            holds: holds,
            sections: sections,
            conflicts: approvalValues.2,
            generatedAt: now
        )
        return SyncPreparation(
            outcome: .plan(plan),
            preview: preview,
            runID: runID,
            syncSetName: "Documents"
        )
    }

    private static var approvalPlanValues: ([ItemDecision], OperationSchedule, [ConflictDecision]) {
        let version = ItemVersion(contentHash: "fixture", size: 512, modifiedAt: now)
        let trashID = OperationID(id(50))
        let trashPath: SyncPath = "/Documents/Archive/Obsolete.txt"
        let operation = Operation(
            id: trashID,
            location: .googleDrive,
            kind: .trash(
                itemRef: ItemRef(
                    location: .googleDrive,
                    itemID: "fixture-trash",
                    path: trashPath,
                    kind: .file,
                    expectedVersion: version
                )
            ),
            precondition: .versionMatches(version)
        )
        let conflict = ConflictDecision(
            id: id(51),
            syncSetID: syncSetID,
            path: "/Documents/Budget.xlsx",
            message: ActivityMessageCatalog.conflictPreserved
        )
        return (
            [
                ItemDecision(
                    id: id(52),
                    path: trashPath,
                    verdict: .propagateDeletion(to: [.googleDrive], initiatedBy: .iCloudDrive),
                    operations: [trashID],
                    explanation: "Move matching copies to trash."
                ),
                ItemDecision(
                    id: id(53),
                    path: conflict.path,
                    verdict: .conflict(conflict),
                    operations: [],
                    explanation: conflict.message
                ),
            ],
            OperationSchedule(operations: [operation]),
            [conflict]
        )
    }

    private static let populatedSections: [PreviewSection] = [
        section(.additions, path: "/Documents/Notes/From iPhone.txt", summary: "Create \"/Documents/Notes/From iPhone.txt\" in 2 locations."),
        section(.updates, path: "/Documents/Notes/Meeting.txt", summary: "Update \"/Documents/Notes/Meeting.txt\" in Google Drive from iCloud Drive."),
        section(.movesAndRenames, path: "/Documents/Archive/Renamed Reference.txt", summary: "Rename the matching copies in 2 locations."),
        section(.waiting, path: "/Documents/Notes/Cloud Placeholder.pages", summary: "Waiting for \"Cloud Placeholder.pages\" to download from iCloud Drive."),
        PreviewSection(
            kind: .movesToTrash,
            entries: [
                PreviewEntry(
                    decisionID: id(52),
                    path: "/Documents/Archive/Obsolete.txt",
                    summary: "Move \"/Documents/Archive/Obsolete.txt\" to 2 locations' trash.",
                    causality: "Deleted from Google Drive since last sync on 2026-07-10T12:00:00Z. Copies at other locations move to trash.",
                    destinations: [.iCloudDrive, .localFolder],
                    isTrash: true
                ),
            ]
        ),
        section(.bothVersionsPreserved, path: "/Documents/Budget.xlsx", summary: ActivityMessageCatalog.conflictPreserved),
    ]

    private static func section(
        _ kind: PreviewSectionKind,
        path: SyncPath,
        summary: String
    ) -> PreviewSection {
        PreviewSection(
            kind: kind,
            entries: [
                PreviewEntry(
                    decisionID: id(sectionID(kind)),
                    path: path,
                    summary: summary,
                    destinations: [.googleDrive, .localFolder],
                    byteSize: 1_024
                ),
            ]
        )
    }

    private static func sectionID(_ kind: PreviewSectionKind) -> Int {
        switch kind {
        case .additions: 1
        case .updates: 2
        case .movesAndRenames: 3
        case .waiting: 4
        case .movesToTrash: 5
        case .bothVersionsPreserved: 6
        }
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", suffix)) ?? UUID()
    }
}

private extension SyncRunSummary {
    static let drift = SyncRunSummary(
        runID: UUID(uuidString: "60000000-0000-0000-0000-000000000060") ?? UUID(),
        syncSetID: UUID(uuidString: "60000000-0000-0000-0000-000000000001") ?? UUID(),
        outcome: .stoppedForReplan(location: .googleDrive, path: "/Documents/Notes/Meeting.txt")
    )
}
