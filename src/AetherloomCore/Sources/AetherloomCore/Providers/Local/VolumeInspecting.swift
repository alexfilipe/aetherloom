import Foundation

public enum VolumeMountState: Hashable, Sendable {
    case mounted
    case notMounted(detail: String)
    case indeterminate(detail: String)
}

public enum VolumeResponsiveness: Hashable, Sendable {
    case responsive
    case unreachable(detail: String)
}

public enum InspectedDirectoryState: Hashable, Sendable {
    case present(isReadable: Bool)
    case missing
    case unknown(detail: String)
}

public struct VolumeProperties: Hashable, Sendable {
    public var isCaseSensitive: Bool?
    public var supportsNativeTrash: Bool
    public var isNetwork: Bool?

    public init(
        isCaseSensitive: Bool?,
        supportsNativeTrash: Bool,
        isNetwork: Bool?
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.supportsNativeTrash = supportsNativeTrash
        self.isNetwork = isNetwork
    }
}

public protocol VolumeInspecting: Sendable {
    func mountState(for rootURL: URL) async -> VolumeMountState
    func responsiveness(for rootURL: URL) async -> VolumeResponsiveness
    func properties(for rootURL: URL) async -> VolumeProperties?
    func directoryState(at url: URL) async -> InspectedDirectoryState
    func volumeIdentity(for url: URL) async -> String?
}

public struct SystemVolumeInspector: VolumeInspecting {
    public init() {}

    public func mountState(for rootURL: URL) async -> VolumeMountState {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLKey],
            options: []
        ) ?? []
        let rootPath = rootURL.standardizedFileURL.path

        if let expectedMountPath = Self.expectedVolumesMountPath(for: rootPath) {
            if mounted.contains(where: { $0.standardizedFileURL.path == expectedMountPath }) {
                return .mounted
            }
            return .notMounted(detail: "Expected volume at \(expectedMountPath) is not mounted.")
        }

        if (try? rootURL.resourceValues(forKeys: [.volumeURLKey]).volume) != nil {
            return .mounted
        }

        if mounted.contains(where: { Self.contains(rootPath, in: $0.standardizedFileURL.path) }) {
            return .mounted
        }
        return .indeterminate(detail: "The volume containing \(rootPath) could not be identified.")
    }

    public func responsiveness(for rootURL: URL) async -> VolumeResponsiveness {
        let probeURL = Self.probeURL(for: rootURL)
        do {
            _ = try probeURL.resourceValues(forKeys: [.volumeURLKey, .isReadableKey])
            return .responsive
        } catch {
            return .unreachable(detail: String(describing: error))
        }
    }

    public func properties(for rootURL: URL) async -> VolumeProperties? {
        let probeURL = Self.probeURL(for: rootURL)
        guard let values = try? probeURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey, .volumeIsLocalKey]
        ) else {
            return nil
        }

        let trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: rootURL,
            create: false
        )
        return VolumeProperties(
            isCaseSensitive: values.volumeSupportsCaseSensitiveNames,
            supportsNativeTrash: trashURL != nil,
            isNetwork: values.volumeIsLocal.map(!)
        )
    }

    public func directoryState(at url: URL) async -> InspectedDirectoryState {
        do {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isReadableKey]
            )
            guard values.isDirectory == true else {
                return .unknown(detail: "\(url.path) is not a directory.")
            }
            return .present(
                isReadable: values.isReadable
                    ?? FileManager.default.isReadableFile(atPath: url.path)
            )
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError {
                return .missing
            }
            return .unknown(detail: String(describing: error))
        }
    }

    public func volumeIdentity(for url: URL) async -> String? {
        guard let identifier = try? url.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }

    private static func probeURL(for rootURL: URL) -> URL {
        var candidate = rootURL
        var isDirectory = ObjCBool(false)
        while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func expectedVolumesMountPath(for path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3, components[1] == "Volumes" else {
            return nil
        }
        return "/Volumes/\(components[2])"
    }

    private static func contains(_ path: String, in mountPath: String) -> Bool {
        mountPath == "/" || path == mountPath || path.hasPrefix(mountPath + "/")
    }
}
