import AetherloomBridge
import AetherloomCore
import SwiftUI

private enum ConflictTab: String, CaseIterable, Identifiable {
    case open
    case resolved

    var id: Self { self }
}

struct ConflictsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("conflicts.dismissedAdviceIDs") private var dismissedAdviceStorage = ""

    @State private var selectedTab = ConflictTab.open
    @State private var highlightedConflictID: UUID?

    private var openDisplays: [ConflictDisplay] {
        appModel.openConflicts.map { conflict in
            conflictDisplay(
                for: conflict,
                advice: dismissedAdviceIDs.contains(conflict.id) ? nil : appModel.conflictAdviceByID[conflict.id],
                locations: appModel.workspace?.locations ?? [],
                plan: plan(for: conflict.id)
            )
        }
    }

    private var dismissedAdviceIDs: Set<UUID> {
        Set(dismissedAdviceStorage.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PageHeader(
                        title: "Conflicts",
                        subtitle: "Files that changed in more than one place. Every version is safe."
                    )

                    Picker("Conflict status", selection: $selectedTab) {
                        Text("Open (\(appModel.openConflicts.count))")
                            .liveNumericTransition()
                            .tag(ConflictTab.open)
                        Text("Resolved").tag(ConflictTab.resolved)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    switch selectedTab {
                    case .open:
                        openContent
                    case .resolved:
                        resolvedContent
                    }
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ContentBackdrop())
            .task(id: appModel.focusedConflictID) {
                guard let id = appModel.focusedConflictID else { return }
                if appModel.openConflicts.contains(where: { $0.id == id }) {
                    selectedTab = .open
                } else if appModel.resolvedConflicts.contains(where: { $0.id == id }) {
                    selectedTab = .resolved
                } else {
                    appModel.clearConflictFocus(id)
                    return
                }

                await Task.yield()
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                    proxy.scrollTo(id, anchor: .center)
                    highlightedConflictID = id
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                    highlightedConflictID = nil
                }
                appModel.clearConflictFocus(id)
            }
        }
    }

    @ViewBuilder
    private var openContent: some View {
        if openDisplays.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.seal.fill",
                title: "No conflicts",
                message: "When a file changes in more than one place, it appears here with every version preserved."
            )
        } else {
            ForEach(openDisplays) { conflict in
                ConflictCard(
                    conflict: conflict,
                    detectedAt: detectedAt(for: conflict.id),
                    isHighlighted: highlightedConflictID == conflict.id,
                    dismissAdvice: { dismissAdvice(for: conflict.id) },
                    resolve: { resolution in
                        Task { await appModel.resolveConflict(conflict.id, as: resolution) }
                    }
                )
                .id(conflict.id)
            }
        }
    }

    @ViewBuilder
    private var resolvedContent: some View {
        if appModel.resolvedConflicts.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: "No resolved conflicts yet",
                message: "Recorded choices appear here and take effect on the next sync."
            )
        } else {
            ForEach(appModel.resolvedConflicts) { record in
                ResolvedConflictCard(
                    record: record,
                    locations: appModel.workspace?.locations ?? [],
                    isHighlighted: highlightedConflictID == record.id
                )
                .id(record.id)
            }
        }
    }

    private func dismissAdvice(for id: UUID) {
        var ids = dismissedAdviceIDs
        ids.insert(id)
        dismissedAdviceStorage = ids.map(\.uuidString).sorted().joined(separator: "\n")
    }

    private func plan(for conflictID: UUID) -> SyncPlan? {
        appModel.preparations.values.first(where: {
            $0.preview.conflicts.contains(where: { $0.id == conflictID })
        })?.outcome.planValue
    }

    private func detectedAt(for conflictID: UUID) -> Date? {
        appModel.preparations.values.first(where: {
            $0.preview.conflicts.contains(where: { $0.id == conflictID })
        })?.preview.generatedAt
    }
}

private struct ConflictCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var conflict: ConflictDisplay
    var detectedAt: Date?
    var isHighlighted: Bool
    var dismissAdvice: () -> Void
    var resolve: (ConflictDecision.Resolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Text(conflict.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(conflict.versions) { version in
                    VersionRow(version: version) {
                        resolve(.makeCanonical(version.id))
                    }
                }
            }

            if let preservedCopyName = conflict.preservedCopyName {
                Label("Kept as “\(preservedCopyName)”", systemImage: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let advice = conflict.advice {
                AdviceChip(advice: advice, onDismiss: dismissAdvice)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    resolve(.preserveAll)
                } label: {
                    Label("Keep Both", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .help("Both versions stay where they are.")

                // 🎭 placeholder: file comparison — see
                // architecture/ui/11-functioning-vs-placeholder.md.
                Button("Compare…") {}
                    .disabled(true)
                PlaceholderChip(text: "File comparison coming soon")

                Spacer()

                Text("Your choice is applied on the next sync.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .card(hoverLift: false)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Theme.accent.opacity(isHighlighted ? 0.9 : 0), lineWidth: 2)
                .shadow(color: Theme.accent.opacity(isHighlighted ? 0.28 : 0), radius: 9)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth, value: isHighlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(conflict.path.name), needs review, \(conflict.versions.count) \(conflict.versions.count == 1 ? "version" : "versions"). \(conflict.message)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.on.doc.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.path.name)
                    .font(.title3.weight(.semibold))
                PathText(conflict.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detectedAt {
                    Text("Detected \(DisplayFormatting.relativeDate(detectedAt, now: Date()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(DisplayFormatting.absoluteDate(detectedAt))
                }
            }

            Spacer()
            StatusBadge(text: "Needs review", tone: .attention)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(conflict.path.name), needs review, \(conflict.versions.count) \(conflict.versions.count == 1 ? "version" : "versions")"
        )
    }
}

private struct VersionRow: View {
    var version: VersionDisplay
    var choose: () -> Void

    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 12) {
            ServiceMark(provider: version.location.provider, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(version.location.displayName)
                        .font(.subheadline.weight(.semibold))
                    if version.isMostRecent {
                        Text("Most recent")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.10), in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    Text(version.modifiedAt.map { DisplayFormatting.absoluteDate($0) } ?? "Modified date unavailable")
                    Text(version.byteSize.map { DisplayFormatting.byteCount($0) } ?? "Size unavailable")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Choose This Version") {
                isConfirming = true
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isConfirming, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Make the \(version.location.displayName) version the one everywhere? The other version stays preserved as a conflict copy.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Applied on the next sync.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            isConfirming = false
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Choose Version") {
                            isConfirming = false
                            choose()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(18)
                .frame(width: 360)
            }
            .accessibilityLabel("Choose the \(version.location.displayName) version")
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct ResolvedConflictCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var record: ConflictResolutionRecord
    var locations: [LocationState]
    var isHighlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(record.conflict.path.name)
                    .font(.headline)
                PathText(record.conflict.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(resolutionText)
                    .font(.subheadline)
                Text("Applied on the next sync.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Recorded \(DisplayFormatting.relativeDate(record.resolvedAt, now: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(DisplayFormatting.absoluteDate(record.resolvedAt))
            }

            Spacer()
            StatusBadge(text: "Resolved", tone: .healthy)
        }
        .card(hoverLift: false)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Theme.accent.opacity(isHighlighted ? 0.9 : 0), lineWidth: 2)
                .shadow(color: Theme.accent.opacity(isHighlighted ? 0.28 : 0), radius: 9)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth, value: isHighlighted)
        .accessibilityElement(children: .combine)
    }

    private var resolutionText: String {
        switch record.resolution {
        case .preserveAll:
            "Both versions stay where they are."
        case let .makeCanonical(locationID):
            "The \(locationName(locationID)) version will be the one everywhere. The other version stays preserved as a conflict copy."
        }
    }

    private func locationName(_ id: LocationID) -> String {
        locations.first(where: { $0.id == id })?.location.displayName ?? id.displayName
    }
}

// MARK: - Previews

private struct ConflictsPreviewHost: View {
    @State private var model: AppModel
    private let initialTab: ConflictTab

    init(_ fixture: ConflictsPreviewFixture, initialTab: ConflictTab = .open) {
        self.initialTab = initialTab
        let session = PreviewEngineSession(
            snapshot: fixture.workspace,
            openConflicts: fixture.open,
            resolvedConflicts: fixture.resolved,
            advice: fixture.advice
        )
        _model = State(initialValue: AppModel(
            session: session,
            bootstrapImmediately: false,
            initialWorkspace: fixture.workspace,
            initialPhase: .ready,
            initialPreparations: fixture.preparations,
            initialOpenConflicts: fixture.open,
            initialResolvedConflicts: fixture.resolved,
            initialConflictAdvice: fixture.advice
        ))
    }

    var body: some View {
        ConflictsView()
            .environment(model)
            .tint(Theme.accent)
            .frame(width: 960, height: 820)
            .onAppear {
                if initialTab == .resolved, let id = model.resolvedConflicts.first?.id {
                    model.show(.conflicts, focusing: id)
                }
            }
    }
}

private struct ConflictsPreviewFixture {
    var workspace: WorkspaceSnapshot
    var open: [ConflictDecision] = []
    var resolved: [ConflictResolutionRecord] = []
    var advice: [ConflictAdvice] = []
    var preparations: [UUID: SyncPreparation] = [:]

    static let withAdvice = make(includeAdvice: true)
    static let withoutAdvice = make(includeAdvice: false)
    static let resolved = makeResolved()
    static let empty = ConflictsPreviewFixture(workspace: workspace(openCount: 0))

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let conflictID = id(1)
    private static let path: SyncPath = "/Documents/Budget.xlsx"

    private static func make(includeAdvice: Bool) -> ConflictsPreviewFixture {
        let conflict = conflictValue()
        let preparation = preparationValue(conflict: conflict)
        let advice = includeAdvice ? [adviceValue()] : []
        return ConflictsPreviewFixture(
            workspace: workspace(openCount: 1),
            open: [conflict],
            advice: advice,
            preparations: [DemoWorld.documentsID: preparation]
        )
    }

    private static func makeResolved() -> ConflictsPreviewFixture {
        let conflict = conflictValue()
        return ConflictsPreviewFixture(
            workspace: workspace(openCount: 0),
            resolved: [
                ConflictResolutionRecord(
                    id: conflict.id,
                    conflict: conflict,
                    resolution: .makeCanonical(.googleDrive),
                    resolvedAt: now.addingTimeInterval(-600)
                ),
            ]
        )
    }

    private static func workspace(openCount: Int) -> WorkspaceSnapshot {
        let world = DemoWorld.standard
        return WorkspaceSnapshot(
            locations: world.locations.map {
                LocationState(
                    location: $0,
                    availability: .available,
                    lastCheckedAt: now,
                    accountLabel: world.accountLabels[$0.id]
                )
            },
            syncSets: [],
            openConflictCount: openCount,
            status: openCount == 0 ? .allInSync : .needsReview(count: openCount)
        )
    }

    private static func conflictValue() -> ConflictDecision {
        let iCloudVersion = ItemVersion(
            contentHash: "icloud-budget",
            size: 42_100,
            modifiedAt: now.addingTimeInterval(-172_800),
            revisionToken: "icloud-1"
        )
        let googleVersion = ItemVersion(
            contentHash: "google-budget",
            size: 44_320,
            modifiedAt: now,
            revisionToken: "google-2"
        )
        return ConflictDecision(
            id: conflictID,
            syncSetID: DemoWorld.documentsID,
            path: path,
            versions: [
                AetherloomCore.ConflictVersion(
                    location: .iCloudDrive,
                    observation: ItemObservation(
                        location: .iCloudDrive,
                        itemID: "icloud-budget",
                        path: path,
                        kind: .file,
                        version: iCloudVersion
                    )
                ),
                AetherloomCore.ConflictVersion(
                    location: .googleDrive,
                    observation: ItemObservation(
                        location: .googleDrive,
                        itemID: "google-budget",
                        path: path,
                        kind: .file,
                        version: googleVersion
                    )
                ),
            ],
            message: ActivityMessageCatalog.conflictPreserved
        )
    }

    private static func adviceValue() -> ConflictAdvice {
        ConflictAdvice(
            conflictID: conflictID,
            recommended: .makeCanonical(.googleDrive),
            confidence: .medium,
            rationale: "The Google Drive version was edited two days later, so it is likely the version you meant to keep current.",
            perVersionNotes: [
                .iCloudDrive: "Edited two days earlier",
                .googleDrive: "Edited most recently",
            ],
            generatedBy: .heuristic,
            generatedAt: now
        )
    }

    private static func preparationValue(conflict: ConflictDecision) -> SyncPreparation {
        let operationID = OperationID(id(2))
        let source = conflict.versions[1].observation
        let preservedPath: SyncPath = "/Documents/Budget (conflict from Google Drive, Jul 10 2026).xlsx"
        let operation = Operation(
            id: operationID,
            location: .iCloudDrive,
            kind: .transfer(content: ContentRef(source), to: preservedPath, overwrite: .neverOverwrite),
            precondition: .pathAbsent
        )
        let decision = ItemDecision(
            id: id(3),
            path: conflict.path,
            verdict: .conflict(conflict),
            operations: [operationID],
            explanation: conflict.message
        )
        let fingerprint = PlanFingerprint(rawValue: "conflicts-preview")
        let plan = SyncPlan(
            syncSetID: DemoWorld.documentsID,
            generatedAt: now,
            decisions: [decision],
            schedule: OperationSchedule(operations: [operation]),
            conflicts: [conflict],
            gate: .hold([.conflicts(count: 1)]),
            fingerprint: fingerprint
        )
        let preview = ChangePreview(
            syncSetID: DemoWorld.documentsID,
            planFingerprint: fingerprint,
            headline: "Changes need review",
            conflicts: [conflict],
            generatedAt: now
        )
        return SyncPreparation(
            outcome: .plan(plan),
            preview: preview,
            advice: [adviceValue()],
            runID: id(4),
            syncSetName: "Documents"
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "70000000-0000-0000-0000-%012d", suffix))!
    }
}

#Preview("Open with advice") {
    ConflictsPreviewHost(.withAdvice)
}

#Preview("Open without advice") {
    ConflictsPreviewHost(.withoutAdvice)
}

#Preview("Resolved") {
    ConflictsPreviewHost(.resolved, initialTab: .resolved)
}

#Preview("Empty") {
    ConflictsPreviewHost(.empty)
}
