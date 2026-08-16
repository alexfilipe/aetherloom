import AetherloomSystemSupport
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LocalDataForkCopyKind: Hashable, Sendable {
    case file
    case directoryTree
}

protocol LocalDataForkCopying: Sendable {
    func copyItem(
        at source: URL,
        to destination: URL,
        kind: LocalDataForkCopyKind
    ) throws

    func replaceItem(at destination: URL, withItemAt source: URL) throws
}

struct SystemLocalDataForkCopier: LocalDataForkCopying {
    func copyItem(
        at source: URL,
        to destination: URL,
        kind: LocalDataForkCopyKind
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(EINVAL) }
                return aetherloom_copy_data_fork(
                    sourcePath,
                    destinationPath,
                    kind == .directoryTree ? 1 : 0
                )
            }
        }
        guard result == 0 else { throw posixError(result) }
        try applySynchronizedModificationTimes(
            from: source,
            to: destination,
            kind: kind
        )
    }

    func replaceItem(at destination: URL, withItemAt source: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(EINVAL) }
                return aetherloom_replace_item(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError(result) }
    }

    private func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func applySynchronizedModificationTimes(
        from source: URL,
        to destination: URL,
        kind: LocalDataForkCopyKind
    ) throws {
        switch kind {
        case .file:
            try applyRegularFileModificationTime(
                from: source,
                to: destination
            )
        case .directoryTree:
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let sourceItem as URL in enumerator {
                let values = try sourceItem.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    throw CocoaError(.fileReadUnknown)
                }
                guard values.isRegularFile == true else { continue }
                let destinationItem = try correspondingDestination(
                    for: sourceItem,
                    sourceRoot: source,
                    destinationRoot: destination
                )
                try applyRegularFileModificationTime(
                    from: sourceItem,
                    to: destinationItem
                )
            }
            if enumerationError != nil {
                throw CocoaError(.fileReadUnknown)
            }
        }
    }

    private func correspondingDestination(
        for sourceItem: URL,
        sourceRoot: URL,
        destinationRoot: URL
    ) throws -> URL {
        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        let itemComponents = sourceItem.standardizedFileURL.pathComponents
        guard itemComponents.starts(with: rootComponents),
              itemComponents.count > rootComponents.count else {
            throw CocoaError(.fileReadUnknown)
        }
        return itemComponents.dropFirst(rootComponents.count).reduce(
            destinationRoot
        ) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func applyRegularFileModificationTime(
        from source: URL,
        to destination: URL
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    return Int32(EINVAL)
                }
                return aetherloom_apply_regular_file_modification_time(
                    sourcePath,
                    destinationPath
                )
            }
        }
        guard result == 0 else { throw posixError(result) }
    }
}
