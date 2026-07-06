import Foundation

public struct ConflictResolver: Sendable {
    public var generatedAt: Date

    public init(generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
    }

    public func conflictPath(for item: CloudItem, existingPaths: Set<CloudPath> = []) -> CloudPath {
        let providerName = item.provider.displayName
        let timestamp = Self.timestampString(from: generatedAt)
        let baseName = item.path.deletingPathExtensionName
        let extensionValue = item.path.pathExtension
        let suffix = " (conflict from \(providerName), \(timestamp))"
        var candidateName = baseName + suffix
        if !extensionValue.isEmpty {
            candidateName += "." + extensionValue
        }

        var candidate = item.path.parent.appending(candidateName)
        var counter = 2
        while existingPaths.contains(candidate) {
            var numberedName = baseName + suffix + " \(counter)"
            if !extensionValue.isEmpty {
                numberedName += "." + extensionValue
            }
            candidate = item.path.parent.appending(numberedName)
            counter += 1
        }
        return candidate
    }

    private static func timestampString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}

