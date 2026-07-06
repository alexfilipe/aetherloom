import Foundation

enum ContentHashing {
    static func hash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "fnv1a64-%016llx", hash)
    }
}
