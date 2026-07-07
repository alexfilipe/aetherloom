import CryptoKit
import Foundation

enum CanonicalCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateString(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO-8601 date with fractional seconds."
                )
            }
            return date
        }
        return decoder
    }

    static func dateString(_ date: Date) -> String {
        fractionalDateFormatter().string(from: date)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func date(from string: String) -> Date? {
        fractionalDateFormatter().date(from: string) ?? wholeSecondDateFormatter().date(from: string)
    }

    private static func fractionalDateFormatter() -> ISO8601DateFormatter {
        let key = "Aetherloom.CanonicalCoding.fractionalDateFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    private static func wholeSecondDateFormatter() -> ISO8601DateFormatter {
        let key = "Aetherloom.CanonicalCoding.wholeSecondDateFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
}

enum DeterministicID {
    static func uuid(_ parts: String...) -> UUID {
        let joined = parts.joined(separator: "\u{1f}")
        var bytes = Array(SHA256.hash(data: Data(joined.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
