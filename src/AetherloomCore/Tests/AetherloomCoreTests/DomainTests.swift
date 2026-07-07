import Foundation
import Testing
@testable import AetherloomCore

@Test func syncPathNormalizesRelativeWhitespaceAndRoot() {
    #expect(SyncPath(" Documents//Reports/ ").rawValue == "/Documents/Reports")
    #expect(SyncPath("").rawValue == "/")
    #expect(SyncPath("/").isRoot)
    #expect(SyncPath("/Documents/Reports/Q1.pdf").parent == "/Documents/Reports")
    #expect(SyncPath("/Documents/Reports/Q1.pdf").pathExtension == "pdf")
}

@Test func syncPathCaseAndDiacriticFoldKeyCollidesConservatively() {
    let composed = SyncPath("/Résumé.txt")
    let plainUppercase = SyncPath("/RESUME.txt")

    #expect(composed != plainUppercase)
    #expect(composed.caseInsensitiveKey == plainUppercase.caseInsensitiveKey)
}

@Test func syncSettingsBuiltInAndSymlinkExclusionsAreNonRemovable() {
    let settings = SyncSettings()
    let symlink = ItemObservation(
        location: .localFolder,
        path: "/Linked",
        kind: .symlink(target: "/Volumes/External")
    )

    #expect(settings.isExcluded("/.aetherloom"))
    #expect(settings.isExcluded("/.aetherloom/trash/run/file.txt"))
    #expect(settings.isExcluded(symlink))
}

@Test func conflictNamingIsDeterministicAndCollisionSuffixed() {
    let environment = PlanningEnvironment(
        now: domainDate,
        locationNames: [.oneDrive: "OneDrive Work"]
    )
    let resolver = ConflictResolver(environment: environment)
    let item = ItemObservation(location: .oneDrive, path: "/Money/Budget.final.xlsx", kind: .file)
    let first = resolver.conflictPath(for: item)
    let second = resolver.conflictPath(for: item, existingPaths: [first])

    #expect(first == "/Money/Budget.final (conflict from OneDrive Work, 2026-02-02 02-40-00).xlsx")
    #expect(second == "/Money/Budget.final (conflict from OneDrive Work, 2026-02-02 02-40-00) 2.xlsx")
}

private let domainDate = Date(timeIntervalSince1970: 1_770_000_000)
