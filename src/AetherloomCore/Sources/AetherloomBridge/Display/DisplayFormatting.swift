import AetherloomCore
import Foundation

public enum DisplayFormatting {
    public static func relativeDate(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded(.towardZero))
        if abs(seconds) < 60 {
            return seconds >= 0 ? "just now" : "in a moment"
        }
        let minutes = abs(seconds) / 60
        if minutes < 60 {
            return relative(minutes, unit: "minute", past: seconds >= 0)
        }
        let hours = minutes / 60
        if hours < 24 {
            return relative(hours, unit: "hour", past: seconds >= 0)
        }
        let days = hours / 24
        if days < 7 {
            return relative(days, unit: "day", past: seconds >= 0)
        }
        let weeks = days / 7
        if weeks < 5 {
            return relative(weeks, unit: "week", past: seconds >= 0)
        }
        let months = days / 30
        if months < 12 {
            return relative(max(months, 1), unit: "month", past: seconds >= 0)
        }
        return relative(max(days / 365, 1), unit: "year", past: seconds >= 0)
    }

    public static func absoluteDate(
        _ date: Date,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func byteCount(
        _ bytes: Int64,
        locale: Locale = Locale(identifier: "en_US")
    ) -> String {
        if #available(macOS 12.0, *) {
            return bytes.formatted(.byteCount(style: .file).locale(locale))
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func fileCount(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    public static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }

    public static func preparationSummary(_ digest: PreparationDigest) -> String {
        let labels: [(PreviewSectionKind, String, String)] = [
            (.updates, "update", "updates"),
            (.additions, "addition", "additions"),
            (.movesAndRenames, "move", "moves"),
            (.movesToTrash, "trash move", "trash moves"),
            (.bothVersionsPreserved, "conflict", "conflicts"),
            (.waiting, "item waiting", "items waiting"),
        ]
        let parts = labels.compactMap { kind, singular, plural -> String? in
            let count = digest.sectionCounts[kind] ?? 0
            guard count > 0 else { return nil }
            return "\(count) \(count == 1 ? singular : plural)"
        }
        return parts.isEmpty ? "No changes waiting" : parts.joined(separator: ", ")
    }

    public static func middleTruncatedPath(_ path: SyncPath, maxLength: Int) -> String {
        let value = path.rawValue
        guard maxLength > 0, value.count > maxLength else { return value }
        guard maxLength >= 5 else { return String(value.prefix(maxLength)) }
        let available = maxLength - 1
        let prefixCount = (available + 1) / 2
        let suffixCount = available / 2
        return String(value.prefix(prefixCount)) + "…" + String(value.suffix(suffixCount))
    }

    private static func relative(_ value: Int, unit: String, past: Bool) -> String {
        let label = value == 1 ? unit : unit + "s"
        return past ? "\(value) \(label) ago" : "in \(value) \(label)"
    }
}
