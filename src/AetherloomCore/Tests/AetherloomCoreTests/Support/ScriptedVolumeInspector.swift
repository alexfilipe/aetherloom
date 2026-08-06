import Foundation
@testable import AetherloomCore

enum ScriptedVolumeInspectionCall: Hashable, Sendable {
    case mount
    case responsiveness
    case properties
    case volumeIdentity(String)
    case directory(String)
}

actor ScriptedVolumeInspector: VolumeInspecting {
    var mountState: VolumeMountState
    var responsiveness: VolumeResponsiveness
    var volumeProperties: VolumeProperties?
    var defaultDirectoryState: InspectedDirectoryState
    private var directoryStates: [String: InspectedDirectoryState]
    private var recordedCalls: [ScriptedVolumeInspectionCall]
    private var queuedMountStates: [VolumeMountState]
    private var volumeIdentities: [String: String]
    private var defaultVolumeIdentity: String?
    private let lease: TestDirectoryLease?

    init(
        mountState: VolumeMountState = .mounted,
        responsiveness: VolumeResponsiveness = .responsive,
        properties: VolumeProperties? = VolumeProperties(
            isCaseSensitive: false,
            supportsNativeTrash: false,
            isNetwork: false
        ),
        directoryState: InspectedDirectoryState = .present(isReadable: true),
        lease: TestDirectoryLease? = nil
    ) {
        self.mountState = mountState
        self.responsiveness = responsiveness
        self.volumeProperties = properties
        self.defaultDirectoryState = directoryState
        self.directoryStates = [:]
        self.recordedCalls = []
        self.queuedMountStates = []
        self.volumeIdentities = [:]
        self.defaultVolumeIdentity = "scripted-volume"
        self.lease = lease
    }

    func setMountState(_ state: VolumeMountState) {
        mountState = state
    }

    func setResponsiveness(_ state: VolumeResponsiveness) {
        responsiveness = state
    }

    func setProperties(_ properties: VolumeProperties?) {
        volumeProperties = properties
    }

    func enqueueMountStates(_ states: [VolumeMountState]) {
        queuedMountStates.append(contentsOf: states)
    }

    func setVolumeIdentity(_ identity: String?, at url: URL? = nil) {
        if let url, let identity {
            volumeIdentities[volumeIdentityKey(url)] = identity
        } else if let url {
            volumeIdentities.removeValue(forKey: volumeIdentityKey(url))
        } else {
            defaultVolumeIdentity = identity
        }
    }

    func setDirectoryState(_ state: InspectedDirectoryState, at url: URL? = nil) {
        if let url {
            directoryStates[url.standardizedFileURL.path] = state
        } else {
            defaultDirectoryState = state
        }
    }

    func calls() -> [ScriptedVolumeInspectionCall] {
        recordedCalls
    }

    func clearCalls() {
        recordedCalls.removeAll()
    }

    func mountState(for _: URL) async -> VolumeMountState {
        recordedCalls.append(.mount)
        if !queuedMountStates.isEmpty {
            return queuedMountStates.removeFirst()
        }
        return mountState
    }

    func responsiveness(for _: URL) async -> VolumeResponsiveness {
        recordedCalls.append(.responsiveness)
        return responsiveness
    }

    func properties(for _: URL) async -> VolumeProperties? {
        recordedCalls.append(.properties)
        return volumeProperties
    }

    func directoryState(at url: URL) async -> InspectedDirectoryState {
        let path = url.standardizedFileURL.path
        recordedCalls.append(.directory(path))
        return directoryStates[path] ?? defaultDirectoryState
    }

    func volumeIdentity(for url: URL) async -> String? {
        recordedCalls.append(.volumeIdentity(volumeIdentityKey(url)))
        return volumeIdentities[volumeIdentityKey(url)] ?? defaultVolumeIdentity
    }

    private func volumeIdentityKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

final class TestDirectoryLease: @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

struct ImmediateProviderDeadlineClock: ProviderDeadlineClock {
    func sleep(nanoseconds _: UInt64) async throws {}
}

struct FailingProviderDeadlineClock: ProviderDeadlineClock {
    struct ClockFailure: Error {}

    func sleep(nanoseconds _: UInt64) async throws {
        throw ClockFailure()
    }
}

actor ControlledProviderDeadlineClock: ProviderDeadlineClock {
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(nanoseconds _: UInt64) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

actor ControlledDeadlineOperation {
    private var continuation: CheckedContinuation<Int, Never>?

    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func finish(with value: Int) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
