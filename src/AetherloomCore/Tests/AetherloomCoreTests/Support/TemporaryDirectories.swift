import Foundation

enum TestTemporaryDirectory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    static func make(suite: String, name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
            .appendingPathComponent(uniqueName(for: name), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func uniqueName(for name: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "\(name)-\(String(format: "%06d", counter))"
    }
}
