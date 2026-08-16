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
}
