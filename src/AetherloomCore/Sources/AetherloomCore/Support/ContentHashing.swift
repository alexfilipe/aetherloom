import CryptoKit
import Foundation

enum ContentHashing {
    static let chunkSize = 1_048_576

    static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return formatted(digest)
    }

    static func hashFile(at url: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            guard !chunk.isEmpty else { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return (formatted(hasher.finalize()), size)
    }

    private static func formatted<Digest: Sequence>(_ digest: Digest) -> String
    where Digest.Element == UInt8 {
        "sha256-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
