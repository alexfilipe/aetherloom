import Foundation
import Testing
@testable import AetherloomCore

@Test func previewRendererLocksSectionTitlesTrashCausalityAndConflictLanguage() async throws {
    let syncSet = SyncSet(name: "Preview", locations: [.googleDrive, .oneDrive], createdAt: previewDate, updatedAt: previewDate)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleItem = await google.putFile(path: "/TrashMe.txt", contents: previewData("old"), modifiedAt: previewDate)
    let oneDriveItem = await oneDrive.putFile(path: "/TrashMe.txt", contents: previewData("old"), modifiedAt: previewDate)
    let record = BaseRecord(
        syncSetID: syncSet.id,
        path: "/TrashMe.txt",
        kind: .file,
        version: googleItem.version,
        perLocation: [
            .googleDrive: LocationMemory(itemID: googleItem.itemID, revisionToken: googleItem.version.revisionToken, lastSeenAt: previewDate),
            .oneDrive: LocationMemory(itemID: oneDriveItem.itemID, revisionToken: oneDriveItem.version.revisionToken, lastSeenAt: previewDate)
        ],
        lastConvergedAt: previewDate,
        createdAt: previewDate,
        updatedAt: previewDate
    )
    await google.remove(path: "/TrashMe.txt")
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            locations: [
                SyncLocation(id: .googleDrive, kind: .googleDrive, displayName: "Google Drive"),
                SyncLocation(id: .oneDrive, kind: .oneDrive, displayName: "OneDrive")
            ],
            records: [record],
            snapshots: [await google.scan(.entireDrive), await oneDrive.scan(.entireDrive)]
        ),
        environment: PlanningEnvironment(
            now: previewDate,
            locationNames: [.googleDrive: "Google Drive", .oneDrive: "OneDrive"]
        )
    )

    let preview = ChangePreviewRenderer().render(
        outcome: outcome,
        locations: [
            .googleDrive: SyncLocation(id: .googleDrive, kind: .googleDrive, displayName: "Google Drive"),
            .oneDrive: SyncLocation(id: .oneDrive, kind: .oneDrive, displayName: "OneDrive")
        ],
        base: [record],
        generatedAt: previewDate
    )
    let trashEntry = try #require(preview.sections.first { $0.kind == .movesToTrash }?.entries.first)

    #expect(preview.sections.map(\.title) == ["Additions", "Updates", "Moves and renames", "Waiting", "Move to trash", "Both versions preserved"])
    #expect(trashEntry.summary == "Move \"/TrashMe.txt\" to OneDrive trash.")
    #expect(trashEntry.causality == "Deleted from Google Drive since last sync on 2026-02-02T02:40:00.000Z. Copies at other locations move to trash.")
    #expect(ActivityMessageCatalog.conflictPreserved == "This file changed in more than one place. Aetherloom preserved both versions.")
}

@Test func approvalValidationAcceptsOnlyExactDisclosureCounts() {
    let trash = Operation(
        id: OperationID(previewUUID("000000000101")),
        location: .oneDrive,
        kind: .trash(itemRef: ItemRef(ItemObservation(location: .oneDrive, path: "/Delete.txt", kind: .file, version: ItemVersion(contentHash: "old")))),
        precondition: .versionMatches(ItemVersion(contentHash: "old"))
    )
    let conflict = ConflictDecision(
        id: previewUUID("000000000102"),
        path: "/Conflict.txt",
        message: ActivityMessageCatalog.conflictPreserved
    )
    let plan = SyncPlan(
        syncSetID: previewUUID("000000000103"),
        generatedAt: previewDate,
        decisions: [
            ItemDecision(
                id: previewUUID("000000000104"),
                path: "/Delete.txt",
                verdict: .propagateDeletion(to: [.oneDrive], initiatedBy: .googleDrive),
                operations: [trash.id],
                explanation: "Deleted from Google Drive since last sync."
            )
        ],
        schedule: OperationSchedule(operations: [trash]),
        conflicts: [conflict],
        gate: .hold([.deletionsNeedReview(count: 1), .conflicts(count: 1)]),
        fingerprint: PlanFingerprint(rawValue: "preview")
    )

    let accepted = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: previewDate,
        acknowledgedTrashCount: 1,
        acknowledgedConflictCount: 1
    )
    let underDisclosed = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: previewDate,
        acknowledgedTrashCount: 0,
        acknowledgedConflictCount: 1
    )

    #expect(accepted.validate(against: plan, at: previewDate) == .accepted)
    #expect(underDisclosed.validate(against: plan, at: previewDate) == .rejected(.trashCountMismatch(expected: 1, actual: 0)))
}

private func previewData(_ string: String) -> Data {
    Data(string.utf8)
}

private func previewUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "92000000-0000-0000-0000-\(suffix)")!
}

private let previewDate = Date(timeIntervalSince1970: 1_770_000_000)
