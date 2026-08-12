import AetherloomCore

public struct DemoProviderControlDisplay: Sendable, Hashable {
    public var oneDriveIsReachable: Bool
    public var nasIsMounted: Bool

    public init(locations: [LocationState]) {
        oneDriveIsReachable = Self.isAvailable(.oneDrive, in: locations)
        nasIsMounted = Self.isAvailable(.nasFolder, in: locations)
    }

    public var oneDriveActionTitle: String {
        oneDriveIsReachable ? "Make OneDrive Unreachable" : "Make OneDrive Reachable"
    }

    public var nasActionTitle: String {
        nasIsMounted ? "Unmount NAS “Tank”" : "Mount NAS “Tank”"
    }

    private static func isAvailable(
        _ kind: ProviderKind,
        in locations: [LocationState]
    ) -> Bool {
        locations.first(where: { $0.location.kind == kind })?.availability == .available
    }
}
