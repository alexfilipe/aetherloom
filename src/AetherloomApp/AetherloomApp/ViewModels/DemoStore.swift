import SwiftUI
import Observation

// MARK: - Demo model types
//
// These are UI-only placeholder types for the demo shell. The real sync
// engine lives in AetherloomCore and is intentionally not wired up here.

enum CloudService: String, CaseIterable, Identifiable, Hashable {
    case iCloudDrive
    case googleDrive
    case oneDrive
    case localFolder
    case nas

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .localFolder: "Local Folder"
        case .nas: "NAS Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .iCloudDrive: "icloud.fill"
        case .googleDrive: "triangle.fill"
        case .oneDrive: "cloud.fill"
        case .localFolder: "internaldrive.fill"
        case .nas: "server.rack"
        }
    }

    var baseColor: Color {
        switch self {
        case .iCloudDrive: .cyan
        case .googleDrive: .green
        case .oneDrive: .blue
        case .localFolder: .gray
        case .nas: .purple
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .iCloudDrive:
            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .googleDrive:
            LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .oneDrive:
            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .localFolder:
            LinearGradient(
                colors: [Color(red: 0.48, green: 0.53, blue: 0.60), Color(red: 0.28, green: 0.32, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .nas:
            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case syncSets
    case activity
    case conflicts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .syncSets: "Sync Sets"
        case .activity: "Activity"
        case .conflicts: "Conflicts"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "circle.hexagongrid.fill"
        case .syncSets: "folder.badge.gearshape"
        case .activity: "clock.arrow.circlepath"
        case .conflicts: "doc.on.doc"
        case .settings: "gearshape"
        }
    }
}

struct ServiceStatus: Identifiable, Hashable {
    var id: CloudService { service }
    var service: CloudService
    var account: String?
    var selectedFolder: String
    var statusText: String
    var lastChecked: String
    var tone: Tone
    var safetyNote: String?
    var actionTitle: String
}

struct FolderSelection: Identifiable, Hashable {
    var id: CloudService { service }
    var service: CloudService
    var location: String
}

struct SyncSet: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var folders: [FolderSelection]
    var statusText: String
    var tone: Tone
    var lastSync: String
    var trackedFiles: Int
    var pendingSummary: String
    var isPaused: Bool
    var safetyNote: String?
}

struct PlannedChange: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case update
        case create
        case rename
        case moveToTrash
        case conflictCopy

        var title: String {
            switch self {
            case .update: "Update"
            case .create: "Create"
            case .rename: "Rename"
            case .moveToTrash: "Move to trash"
            case .conflictCopy: "Conflict copies"
            }
        }

        var systemImage: String {
            switch self {
            case .update: "square.and.pencil"
            case .create: "plus.square"
            case .rename: "text.cursor"
            case .moveToTrash: "trash"
            case .conflictCopy: "doc.on.doc"
            }
        }

        var tone: Tone {
            switch self {
            case .update, .create, .rename: .healthy
            case .moveToTrash: .neutral
            case .conflictCopy: .attention
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var filename: String
    var path: String
    var detail: String
}

struct ActivityItem: Identifiable, Hashable {
    var id = UUID()
    var time: String
    var service: CloudService?
    var message: String
    var tone: Tone
}

struct ConflictVersion: Identifiable, Hashable {
    var id = UUID()
    var service: CloudService
    var modified: String
    var size: String
}

struct FileConflict: Identifiable, Hashable {
    var id = UUID()
    var filename: String
    var path: String
    var versions: [ConflictVersion]
    var preservedCopyName: String
    var detectedAt: String
    var isResolved = false
}

// MARK: - Demo store

@Observable
@MainActor
final class DemoStore {
    var selectedDestination: SidebarDestination? = .overview

    var services: [ServiceStatus]
    var syncSets: [SyncSet]
    var plannedChanges: [PlannedChange]
    var activity: [ActivityItem]
    var conflicts: [FileConflict]

    // Safety review banner (mass deletions detected in a sync set).
    var massChangeReviewNeeded = true

    // UI state
    var isScanning = false
    var lastScan = "2 minutes ago"
    var showingPreviewChanges = false
    var showingNewSyncSet = false

    // Settings (demo only)
    var moveDeletesToTrash = true
    var pauseOnMassChanges = true
    var requireReviewForWholeDrive = true
    var keepConflictCopies = true

    init() {
        services = Self.sampleServices
        syncSets = Self.sampleSyncSets
        plannedChanges = Self.samplePlannedChanges
        activity = Self.sampleActivity
        conflicts = Self.sampleConflicts
    }

    // MARK: Derived

    var unresolvedConflictCount: Int {
        conflicts.filter { !$0.isResolved }.count
    }

    var pausedSyncSetCount: Int {
        syncSets.filter(\.isPaused).count
    }

    var trackedFileCount: Int {
        syncSets.reduce(0) { $0 + $1.trackedFiles }
    }

    var healthyServiceCount: Int {
        services.filter { $0.tone == .healthy }.count
    }

    var everythingInSync: Bool {
        plannedChanges.isEmpty && unresolvedConflictCount == 0 && !massChangeReviewNeeded
    }

    // MARK: Demo actions

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.smooth) {
                self.isScanning = false
                self.lastScan = "Just now"
                self.activity.insert(
                    ActivityItem(
                        time: "Now",
                        service: nil,
                        message: "Scanned 3 clouds. \(self.plannedChanges.count) changes are waiting for preview.",
                        tone: .healthy
                    ),
                    at: 0
                )
            }
        }
    }

    func applyPlannedChanges() {
        withAnimation(.smooth) {
            for change in plannedChanges.reversed() {
                activity.insert(
                    ActivityItem(
                        time: "Now",
                        service: nil,
                        message: activityMessage(for: change),
                        tone: change.kind.tone
                    ),
                    at: 0
                )
            }
            plannedChanges = []
            lastScan = "Just now"
            for index in syncSets.indices where !syncSets[index].isPaused {
                syncSets[index].statusText = "Up to date"
                syncSets[index].tone = .healthy
                syncSets[index].lastSync = "Just now"
                syncSets[index].pendingSummary = "Nothing waiting"
            }
        }
    }

    func resolveConflict(_ conflict: FileConflict, choice: String) {
        withAnimation(.smooth) {
            guard let index = conflicts.firstIndex(where: { $0.id == conflict.id }) else { return }
            conflicts[index].isResolved = true
            activity.insert(
                ActivityItem(
                    time: "Now",
                    service: nil,
                    message: "Resolved conflict for “\(conflict.filename)” — \(choice). Both versions preserved.",
                    tone: .healthy
                ),
                at: 0
            )
        }
    }

    func approveMassChanges() {
        withAnimation(.smooth) {
            massChangeReviewNeeded = false
            activity.insert(
                ActivityItem(
                    time: "Now",
                    service: nil,
                    message: "You reviewed and approved the pending deletions in “Projects”. Deletions will move to each provider’s trash.",
                    tone: .healthy
                ),
                at: 0
            )
        }
    }

    func togglePause(_ syncSet: SyncSet) {
        guard let index = syncSets.firstIndex(where: { $0.id == syncSet.id }) else { return }
        withAnimation(.smooth) {
            syncSets[index].isPaused.toggle()
            let paused = syncSets[index].isPaused
            syncSets[index].statusText = paused ? "Paused" : "Up to date"
            syncSets[index].tone = paused ? .paused : .healthy
        }
    }

    func addSyncSet(named name: String) {
        withAnimation(.smooth) {
            syncSets.append(
                SyncSet(
                    name: name,
                    folders: [
                        FolderSelection(service: .iCloudDrive, location: "/\(name)"),
                        FolderSelection(service: .googleDrive, location: "/\(name)")
                    ],
                    statusText: "Waiting for first scan",
                    tone: .neutral,
                    lastSync: "Never",
                    trackedFiles: 0,
                    pendingSummary: "Preview changes after the first scan",
                    isPaused: false,
                    safetyNote: nil
                )
            )
        }
    }

    private func activityMessage(for change: PlannedChange) -> String {
        switch change.kind {
        case .update: "Updated “\(change.filename)” — \(change.detail)."
        case .create: "Created “\(change.filename)” — \(change.detail)."
        case .rename: "Renamed “\(change.filename)” — \(change.detail)."
        case .moveToTrash: "Moved “\(change.filename)” to trash — \(change.detail)."
        case .conflictCopy: "Preserved both versions of “\(change.filename)”."
        }
    }
}

// MARK: - Sample data

extension DemoStore {
    static let sampleServices: [ServiceStatus] = [
        ServiceStatus(
            service: .iCloudDrive,
            account: nil,
            selectedFolder: "~/iCloud Drive/Documents",
            statusText: "Connected",
            lastChecked: "2 min ago",
            tone: .healthy,
            safetyNote: nil,
            actionTitle: "Choose Folders"
        ),
        ServiceStatus(
            service: .googleDrive,
            account: "alex@example.com",
            selectedFolder: "/Documents",
            statusText: "Connected",
            lastChecked: "2 min ago",
            tone: .healthy,
            safetyNote: nil,
            actionTitle: "Manage"
        ),
        ServiceStatus(
            service: .oneDrive,
            account: "alex@example.com",
            selectedFolder: "/Documents",
            statusText: "Provider unavailable",
            lastChecked: "14 min ago",
            tone: .paused,
            safetyNote: "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.",
            actionTitle: "Retry"
        ),
        ServiceStatus(
            service: .localFolder,
            account: nil,
            selectedFolder: "~/Documents",
            statusText: "Ready",
            lastChecked: "Just now",
            tone: .healthy,
            safetyNote: nil,
            actionTitle: "Choose Folders"
        ),
        ServiceStatus(
            service: .nas,
            account: "smb://tank.local",
            selectedFolder: "/Volumes/Tank/Media",
            statusText: "Volume asleep",
            lastChecked: "36 min ago",
            tone: .neutral,
            safetyNote: "This volume is asleep or unmounted. Aetherloom waits patiently — files on a sleeping drive are never treated as deleted.",
            actionTitle: "Wake & Mount"
        )
    ]

    static let sampleSyncSets: [SyncSet] = [
        SyncSet(
            name: "Documents",
            folders: [
                FolderSelection(service: .iCloudDrive, location: "/Documents"),
                FolderSelection(service: .googleDrive, location: "/Documents"),
                FolderSelection(service: .oneDrive, location: "/Documents"),
                FolderSelection(service: .localFolder, location: "~/Documents")
            ],
            statusText: "Up to date",
            tone: .healthy,
            lastSync: "2 min ago",
            trackedFiles: 418,
            pendingSummary: "3 updates, 2 creates waiting",
            isPaused: false,
            safetyNote: nil
        ),
        SyncSet(
            name: "Projects",
            folders: [
                FolderSelection(service: .iCloudDrive, location: "/Projects"),
                FolderSelection(service: .googleDrive, location: "/Work/Projects")
            ],
            statusText: "Needs review",
            tone: .attention,
            lastSync: "18 min ago",
            trackedFiles: 1_284,
            pendingSummary: "1 conflict copy preserved",
            isPaused: false,
            safetyNote: "Aetherloom found many deletions. This may be intentional, but sync is paused until you review it."
        ),
        SyncSet(
            name: "Photos Archive",
            folders: [
                FolderSelection(service: .localFolder, location: "~/Pictures/Archive"),
                FolderSelection(service: .nas, location: "/Volumes/Tank/Photos"),
                FolderSelection(service: .googleDrive, location: "/Photos Archive")
            ],
            statusText: "Waiting for volume",
            tone: .neutral,
            lastSync: "36 min ago",
            trackedFiles: 12_408,
            pendingSummary: "Resumes when the NAS wakes — nothing is treated as deleted",
            isPaused: false,
            safetyNote: nil
        ),
        SyncSet(
            name: "Whole Drive Mirror",
            folders: [
                FolderSelection(service: .iCloudDrive, location: "/"),
                FolderSelection(service: .googleDrive, location: "/"),
                FolderSelection(service: .oneDrive, location: "/")
            ],
            statusText: "Paused for safety",
            tone: .paused,
            lastSync: "Never",
            trackedFiles: 0,
            pendingSummary: "Whole-drive sync requires review before the first run",
            isPaused: true,
            safetyNote: nil
        )
    ]

    static let samplePlannedChanges: [PlannedChange] = [
        PlannedChange(
            kind: .update,
            filename: "Resume.docx",
            path: "/Documents/Resume.docx",
            detail: "Google Drive → iCloud Drive"
        ),
        PlannedChange(
            kind: .update,
            filename: "Meeting Notes.md",
            path: "/Documents/Notes/Meeting Notes.md",
            detail: "iCloud Drive → Google Drive"
        ),
        PlannedChange(
            kind: .create,
            filename: "Header.png",
            path: "/Projects/Website/Header.png",
            detail: "New in Google Drive, copying everywhere"
        ),
        PlannedChange(
            kind: .create,
            filename: "index.html",
            path: "/Projects/Website/index.html",
            detail: "New in iCloud Drive, copying everywhere"
        ),
        PlannedChange(
            kind: .rename,
            filename: "Drafts → Drafts 2026",
            path: "/Documents/Drafts",
            detail: "Renamed in iCloud Drive"
        ),
        PlannedChange(
            kind: .moveToTrash,
            filename: "Old Notes.txt",
            path: "/Documents/Old Notes.txt",
            detail: "Deleted in Google Drive — moves to trash elsewhere, recoverable"
        ),
        PlannedChange(
            kind: .conflictCopy,
            filename: "Budget.xlsx",
            path: "/Projects/Budget.xlsx",
            detail: "Changed in two places — both versions preserved"
        )
    ]

    static let sampleActivity: [ActivityItem] = [
        ActivityItem(
            time: "2:34 PM",
            service: .googleDrive,
            message: "Updated “Resume.docx” in Google Drive from iCloud Drive.",
            tone: .healthy
        ),
        ActivityItem(
            time: "2:31 PM",
            service: .iCloudDrive,
            message: "Created folder “Projects/Website” in iCloud Drive.",
            tone: .healthy
        ),
        ActivityItem(
            time: "2:25 PM",
            service: .googleDrive,
            message: "Moved “Old Notes.txt” to Google Drive trash. It stays recoverable for 30 days.",
            tone: .neutral
        ),
        ActivityItem(
            time: "2:19 PM",
            service: .oneDrive,
            message: "Paused for safety — OneDrive became unreachable during a scan. Nothing was deleted.",
            tone: .paused
        ),
        ActivityItem(
            time: "2:04 PM",
            service: .nas,
            message: "“Photos Archive” is waiting — the NAS volume went to sleep. Files on a sleeping drive are never treated as deleted.",
            tone: .neutral
        ),
        ActivityItem(
            time: "2:15 PM",
            service: .iCloudDrive,
            message: "Preserved both versions of “Budget.xlsx” after edits in two places.",
            tone: .attention
        ),
        ActivityItem(
            time: "1:58 PM",
            service: nil,
            message: "Scanned 3 clouds in 4.2 seconds. Everything matched.",
            tone: .healthy
        )
    ]

    static let sampleConflicts: [FileConflict] = [
        FileConflict(
            filename: "Budget.xlsx",
            path: "/Projects/Budget.xlsx",
            versions: [
                ConflictVersion(service: .iCloudDrive, modified: "Today, 2:12 PM", size: "84 KB"),
                ConflictVersion(service: .oneDrive, modified: "Today, 2:09 PM", size: "82 KB")
            ],
            preservedCopyName: "Budget (conflict from OneDrive, 2026-07-03 14-33).xlsx",
            detectedAt: "Today, 2:33 PM"
        )
    ]
}
