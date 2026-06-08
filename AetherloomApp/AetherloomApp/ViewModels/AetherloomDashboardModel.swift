import Combine
import Foundation
import AetherloomCore

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case syncSets
    case activity
    case conflicts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .syncSets:
            "Sync Sets"
        case .activity:
            "Activity"
        case .conflicts:
            "Conflicts"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "sparkles"
        case .syncSets:
            "folder.badge.gearshape"
        case .activity:
            "clock.arrow.circlepath"
        case .conflicts:
            "exclamationmark.triangle"
        case .settings:
            "gearshape"
        }
    }
}

enum AetherloomTone: String, Hashable {
    case healthy
    case attention
    case paused
    case neutral
}

enum ProviderConnectionState: String, Hashable {
    case connected = "Connected"
    case disconnected = "Not connected"
    case folderSelected = "Folder selected"
    case needsAttention = "Needs attention"
}

struct ProviderCardModel: Identifiable, Hashable {
    let id: ProviderID
    var status: ProviderConnectionState
    var account: String?
    var selectedLocation: String?
    var lastChecked: String
    var health: String
    var permissions: String
    var warning: String?
    var actionTitle: String
    var tone: AetherloomTone
}

struct ProviderRootSelection: Identifiable, Hashable {
    var id: ProviderID { provider }
    var provider: ProviderID
    var location: String
}

struct SyncSetSummary: Identifiable, Hashable {
    var id: UUID
    var name: String
    var providers: [ProviderRootSelection]
    var status: String
    var lastSync: String
    var trackedFiles: Int
    var pendingSummary: String
    var conflicts: Int
    var warnings: Int
    var riskLevel: SyncRiskLevel
    var tone: AetherloomTone
}

struct PlanPreviewLine: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var count: Int
    var systemImage: String
    var tone: AetherloomTone
}

struct ActivityLogItem: Identifiable, Hashable {
    var id = UUID()
    var time: String
    var provider: ProviderID?
    var message: String
    var tone: AetherloomTone
}

struct ConflictReviewItem: Identifiable, Hashable {
    var id = UUID()
    var filename: String
    var path: CloudPath
    var providers: [ProviderID]
    var preservedCopyName: String
    var detectedAt: String
}

final class AetherloomDashboardModel: ObservableObject {
    @Published var selectedDestination: SidebarDestination? = .overview
    @Published var providers: [ProviderCardModel]
    @Published var syncSets: [SyncSetSummary]
    @Published var planPreview: [PlanPreviewLine]
    @Published var activity: [ActivityLogItem]
    @Published var conflicts: [ConflictReviewItem]
    @Published var deletePropagationEnabled = true
    @Published var pauseOnMassChanges = true
    @Published var requireReviewForWholeDrive = true

    convenience init() {
        self.init(
            providers: AetherloomDashboardModel.sampleProviders,
            syncSets: AetherloomDashboardModel.sampleSyncSets,
            planPreview: AetherloomDashboardModel.samplePlanPreview,
            activity: AetherloomDashboardModel.sampleActivity,
            conflicts: AetherloomDashboardModel.sampleConflicts
        )
    }

    init(
        providers: [ProviderCardModel],
        syncSets: [SyncSetSummary],
        planPreview: [PlanPreviewLine],
        activity: [ActivityLogItem],
        conflicts: [ConflictReviewItem]
    ) {
        self.providers = providers
        self.syncSets = syncSets
        self.planPreview = planPreview
        self.activity = activity
        self.conflicts = conflicts
    }
}

extension AetherloomDashboardModel {
    var healthyProviderCount: Int {
        providers.filter { $0.tone == .healthy }.count
    }

    var pausedSyncSetCount: Int {
        syncSets.filter { $0.riskLevel == .paused }.count
    }

    var pendingActionCount: Int {
        planPreview.reduce(0) { $0 + $1.count }
    }

    var selectedScreen: SidebarDestination {
        selectedDestination ?? .overview
    }
}

private extension AetherloomDashboardModel {
    static let sampleProviders: [ProviderCardModel] = [
        ProviderCardModel(
            id: .iCloudDrive,
            status: .folderSelected,
            account: nil,
            selectedLocation: "/Documents",
            lastChecked: "2 min ago",
            health: "Ready",
            permissions: "Read and write",
            warning: nil,
            actionTitle: "Choose Folder",
            tone: .healthy
        ),
        ProviderCardModel(
            id: .googleDrive,
            status: .connected,
            account: "alex@example.com",
            selectedLocation: "/Documents",
            lastChecked: "2 min ago",
            health: "Healthy",
            permissions: "Files selected by Aetherloom",
            warning: nil,
            actionTitle: "Manage",
            tone: .healthy
        ),
        ProviderCardModel(
            id: .oneDrive,
            status: .needsAttention,
            account: "alex@example.com",
            selectedLocation: "/Documents",
            lastChecked: "11 min ago",
            health: "Paused for safety",
            permissions: "Recycle bin available",
            warning: "A provider scan was incomplete.",
            actionTitle: "Review",
            tone: .paused
        )
    ]

    static let sampleSyncSets: [SyncSetSummary] = [
        SyncSetSummary(
            id: UUID(),
            name: "Documents",
            providers: [
                ProviderRootSelection(provider: .iCloudDrive, location: "/Documents"),
                ProviderRootSelection(provider: .googleDrive, location: "/Documents"),
                ProviderRootSelection(provider: .oneDrive, location: "/Documents")
            ],
            status: "Healthy",
            lastSync: "2 min ago",
            trackedFiles: 418,
            pendingSummary: "3 edits, 2 creates",
            conflicts: 0,
            warnings: 0,
            riskLevel: .safe,
            tone: .healthy
        ),
        SyncSetSummary(
            id: UUID(),
            name: "Projects",
            providers: [
                ProviderRootSelection(provider: .iCloudDrive, location: "/Projects"),
                ProviderRootSelection(provider: .googleDrive, location: "/Work/Projects"),
                ProviderRootSelection(provider: .oneDrive, location: "/Projects")
            ],
            status: "Needs review",
            lastSync: "18 min ago",
            trackedFiles: 1_284,
            pendingSummary: "1 conflict copy",
            conflicts: 1,
            warnings: 1,
            riskLevel: .needsReview,
            tone: .attention
        ),
        SyncSetSummary(
            id: UUID(),
            name: "Whole Drive Mirror",
            providers: [
                ProviderRootSelection(provider: .iCloudDrive, location: "/"),
                ProviderRootSelection(provider: .googleDrive, location: "/"),
                ProviderRootSelection(provider: .oneDrive, location: "/")
            ],
            status: "Paused",
            lastSync: "Never",
            trackedFiles: 0,
            pendingSummary: "Review required",
            conflicts: 0,
            warnings: 2,
            riskLevel: .paused,
            tone: .paused
        )
    ]

    static let samplePlanPreview: [PlanPreviewLine] = [
        PlanPreviewLine(title: "Files to update", count: 3, systemImage: "square.and.pencil", tone: .healthy),
        PlanPreviewLine(title: "Files to create", count: 2, systemImage: "plus.square", tone: .healthy),
        PlanPreviewLine(title: "Folders to rename", count: 1, systemImage: "text.cursor", tone: .attention),
        PlanPreviewLine(title: "Moved to trash", count: 0, systemImage: "trash", tone: .neutral),
        PlanPreviewLine(title: "Conflict copies", count: 1, systemImage: "doc.on.doc", tone: .attention)
    ]

    static let sampleActivity: [ActivityLogItem] = [
        ActivityLogItem(time: "2:34 PM", provider: .oneDrive, message: "Updated \"Resume.docx\" in OneDrive from Google Drive.", tone: .healthy),
        ActivityLogItem(time: "2:31 PM", provider: .iCloudDrive, message: "Created \"Projects/Website\" in iCloud Drive.", tone: .healthy),
        ActivityLogItem(time: "2:25 PM", provider: .oneDrive, message: "Moved \"Old Notes.txt\" to OneDrive trash.", tone: .attention),
        ActivityLogItem(time: "2:19 PM", provider: .googleDrive, message: "Paused sync because Google Drive returned an incomplete scan.", tone: .paused),
        ActivityLogItem(time: "2:15 PM", provider: .oneDrive, message: "Created conflict copy for \"Budget.xlsx\".", tone: .attention)
    ]

    static let sampleConflicts: [ConflictReviewItem] = [
        ConflictReviewItem(
            filename: "Budget.xlsx",
            path: "/Projects/Budget.xlsx",
            providers: [.iCloudDrive, .oneDrive],
            preservedCopyName: "Budget (conflict from OneDrive, 2026-06-08 14-33-21).xlsx",
            detectedAt: "Today, 2:33 PM"
        )
    ]
}
