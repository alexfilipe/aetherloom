import CryptoKit
import Foundation

enum ContentHashing {
    static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
