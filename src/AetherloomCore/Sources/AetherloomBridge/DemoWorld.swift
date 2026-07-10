import AetherloomCore
import Foundation

public struct DemoWorld: Sendable, Hashable {
    public struct SeedGroup: Sendable, Hashable {
        public var syncSetID: UUID
        public var sourceLocationID: LocationID
        public var items: [Item]

        public init(syncSetID: UUID, sourceLocationID: LocationID, items: [Item]) {
            self.syncSetID = syncSetID
            self.sourceLocationID = sourceLocationID
            self.items = items
        }
    }

    public struct Item: Sendable, Hashable {
        public var path: SyncPath
        public var kind: ItemKind
        public var contents: Data
        public var modifiedAt: Date
        public var itemID: String

        public init(
            path: SyncPath,
            kind: ItemKind,
            contents: Data = Data(),
            modifiedAt: Date,
            itemID: String
        ) {
            self.path = path
            self.kind = kind
            self.contents = contents
            self.modifiedAt = modifiedAt
            self.itemID = itemID
        }
    }

    public struct Divergences: Sendable, Hashable {
        public var documentEditPaths: [SyncPath]
        public var documentCreatePaths: [SyncPath]
        public var documentRename: (old: SyncPath, new: SyncPath)
        public var documentDeletePath: SyncPath
        public var documentConflictPath: SyncPath
        public var documentPlaceholderPath: SyncPath
        public var projectMassDeletionPaths: [SyncPath]

        public init(
            documentEditPaths: [SyncPath],
            documentCreatePaths: [SyncPath],
            documentRename: (old: SyncPath, new: SyncPath),
            documentDeletePath: SyncPath,
            documentConflictPath: SyncPath,
            documentPlaceholderPath: SyncPath,
            projectMassDeletionPaths: [SyncPath]
        ) {
            self.documentEditPaths = documentEditPaths
            self.documentCreatePaths = documentCreatePaths
            self.documentRename = documentRename
            self.documentDeletePath = documentDeletePath
            self.documentConflictPath = documentConflictPath
            self.documentPlaceholderPath = documentPlaceholderPath
            self.projectMassDeletionPaths = projectMassDeletionPaths
        }

        public static func == (lhs: Divergences, rhs: Divergences) -> Bool {
            lhs.documentEditPaths == rhs.documentEditPaths
                && lhs.documentCreatePaths == rhs.documentCreatePaths
                && lhs.documentRename.old == rhs.documentRename.old
                && lhs.documentRename.new == rhs.documentRename.new
                && lhs.documentDeletePath == rhs.documentDeletePath
                && lhs.documentConflictPath == rhs.documentConflictPath
                && lhs.documentPlaceholderPath == rhs.documentPlaceholderPath
                && lhs.projectMassDeletionPaths == rhs.projectMassDeletionPaths
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(documentEditPaths)
            hasher.combine(documentCreatePaths)
            hasher.combine(documentRename.old)
            hasher.combine(documentRename.new)
            hasher.combine(documentDeletePath)
            hasher.combine(documentConflictPath)
            hasher.combine(documentPlaceholderPath)
            hasher.combine(projectMassDeletionPaths)
        }
    }

    public var locations: [SyncLocation]
    public var accountLabels: [LocationID: String]
    public var syncSets: [SyncSet]
    public var pausedSyncSetIDs: Set<UUID>
    public var seedGroups: [SeedGroup]
    public var divergences: Divergences

    public init(
        locations: [SyncLocation],
        accountLabels: [LocationID: String],
        syncSets: [SyncSet],
        pausedSyncSetIDs: Set<UUID>,
        seedGroups: [SeedGroup],
        divergences: Divergences
    ) {
        self.locations = locations
        self.accountLabels = accountLabels
        self.syncSets = syncSets
        self.pausedSyncSetIDs = pausedSyncSetIDs
        self.seedGroups = seedGroups
        self.divergences = divergences
    }

    public static let standard = makeStandard()

    public static let documentsID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    public static let projectsID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    public static let photosArchiveID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    public static let wholeDriveMirrorID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!

    private static let baseDate = Date(timeIntervalSince1970: 1_783_000_000)

    private static func makeStandard() -> DemoWorld {
        let locations = [
            SyncLocation(
                id: .localFolder,
                kind: .localFolder,
                displayName: "Local Folder",
                configuration: ["path": "~/Aetherloom"]
            ),
            SyncLocation(
                id: .nasFolder,
                kind: .nasFolder,
                displayName: "NAS \"Tank\"",
                configuration: ["url": "smb://tank.local"]
            ),
            SyncLocation(id: .iCloudDrive, kind: .iCloudDrive),
            SyncLocation(id: .googleDrive, kind: .googleDrive),
            SyncLocation(id: .oneDrive, kind: .oneDrive),
        ]

        let syncSets = [
            SyncSet(
                id: documentsID,
                name: "Documents",
                locations: [.iCloudDrive, .googleDrive, .localFolder],
                mode: .askBeforeDeleting,
                settings: settings(excluding: ["/Projects", "/Photos"], excludesDSStore: true),
                createdAt: baseDate,
                updatedAt: baseDate
            ),
            SyncSet(
                id: projectsID,
                name: "Projects",
                locations: [.iCloudDrive, .googleDrive],
                settings: settings(excluding: ["/Documents", "/Photos"]),
                createdAt: baseDate,
                updatedAt: baseDate
            ),
            SyncSet(
                id: photosArchiveID,
                name: "Photos Archive",
                locations: [.localFolder, .nasFolder, .googleDrive],
                settings: settings(excluding: ["/Documents", "/Projects"]),
                createdAt: baseDate,
                updatedAt: baseDate
            ),
            SyncSet(
                id: wholeDriveMirrorID,
                name: "Whole Drive Mirror",
                locations: [.iCloudDrive, .googleDrive, .oneDrive],
                createdAt: baseDate,
                updatedAt: baseDate
            ),
        ]

        return DemoWorld(
            locations: locations,
            accountLabels: [
                .localFolder: "~/Aetherloom",
                .nasFolder: "smb://tank.local",
                .iCloudDrive: "alex@icloud.com",
                .googleDrive: "alex@gmail.com",
                .oneDrive: "alex@outlook.com",
            ],
            syncSets: syncSets,
            pausedSyncSetIDs: [wholeDriveMirrorID],
            seedGroups: [
                SeedGroup(syncSetID: documentsID, sourceLocationID: .iCloudDrive, items: documentItems()),
                SeedGroup(syncSetID: projectsID, sourceLocationID: .iCloudDrive, items: projectItems()),
                SeedGroup(syncSetID: photosArchiveID, sourceLocationID: .localFolder, items: photoItems()),
            ],
            divergences: Divergences(
                documentEditPaths: ["/Documents/Notes/Meeting.txt", "/Documents/Plans/Roadmap.md"],
                documentCreatePaths: ["/Documents/Notes/From iPhone.txt", "/Documents/Notes/Local draft.md"],
                documentRename: ("/Documents/Archive/Reference 01.txt", "/Documents/Archive/Renamed Reference.txt"),
                documentDeletePath: "/Documents/Archive/Obsolete.txt",
                documentConflictPath: "/Documents/Budget.xlsx",
                documentPlaceholderPath: "/Documents/Notes/Cloud Placeholder.pages",
                projectMassDeletionPaths: (1 ... 30).map { SyncPath(String(format: "/Projects/Archive/Archived %02d.swift", $0)) }
            )
        )
    }

    private static func settings(excluding prefixes: [String], excludesDSStore: Bool = false) -> SyncSettings {
        var exclusions = prefixes.map {
            SyncExclusion(pattern: $0, matchStyle: .prefix)
        }
        if excludesDSStore {
            exclusions.append(SyncExclusion(pattern: ".DS_Store", matchStyle: .filename))
        }
        return SyncSettings(exclusions: exclusions)
    }

    private static func documentItems() -> [Item] {
        let folders = [
            "/Documents",
            "/Documents/Notes",
            "/Documents/Plans",
            "/Documents/Archive",
            "/Documents/Empty Folder",
        ].map { folder($0) }
        let specialFiles = [
            file("/Documents/Notes/Meeting.txt", "Meeting notes"),
            file("/Documents/Plans/Roadmap.md", "Roadmap v1"),
            file("/Documents/Budget.xlsx", "Budget v1"),
            file("/Documents/Archive/Obsolete.txt", "Old copy"),
            file("/Documents/Notes/Cloud Placeholder.pages", "Materialized before placeholder"),
            file("/Documents/Résumé – 你好.txt", "Unicode works"),
            file("/Documents/zero-byte.dat", ""),
            file("/Documents/.DS_Store", "Finder metadata"),
        ]
        let references = (1 ... 27).map { index in
            file(String(format: "/Documents/Archive/Reference %02d.txt", index), "Reference \(index)")
        }
        return folders + specialFiles + references
    }

    private static func projectItems() -> [Item] {
        let folders = ["/Projects", "/Projects/Archive", "/Projects/Current"].map { folder($0) }
        let archive = (1 ... 30).map { index in
            file(String(format: "/Projects/Archive/Archived %02d.swift", index), "archived \(index)")
        }
        let current = (1 ... 27).map { index in
            file(String(format: "/Projects/Current/Module %02d.swift", index), "module \(index)")
        }
        return folders + archive + current
    }

    private static func photoItems() -> [Item] {
        let folders = ["/Photos", "/Photos/2025", "/Photos/2026"].map { folder($0) }
        let photos = (1 ... 22).map { index in
            file(String(format: "/Photos/2026/IMG_%04d.heic", index), "photo \(index)")
        }
        return folders + photos
    }

    private static func folder(_ path: String) -> Item {
        Item(path: SyncPath(path), kind: .folder, modifiedAt: baseDate, itemID: "demo-folder:\(path)")
    }

    private static func file(_ path: String, _ contents: String) -> Item {
        Item(
            path: SyncPath(path),
            kind: .file,
            contents: Data(contents.utf8),
            modifiedAt: baseDate,
            itemID: "demo-file:\(path)"
        )
    }
}
