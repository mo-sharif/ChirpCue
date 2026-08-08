import CryptoKit
import Foundation

enum GroundingDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func manifest(_ entries: [GroundingManifestEntry]) -> String {
        var bytes = Data("PACENOTE-GROUNDING-MANIFEST-v1\0".utf8)
        append(UInt64(entries.count), to: &bytes)
        for entry in entries {
            append(entry.relativePath, to: &bytes)
            append(entry.byteCount, to: &bytes)
            append(entry.sha256, to: &bytes)
        }
        return sha256(bytes)
    }

    static func grounding(
        manifestFingerprint: String,
        branch: String,
        head: String,
        worktreeFingerprint: String
    ) -> String {
        var bytes = Data("PACENOTE-GROUNDING-SEAL-v1\0".utf8)
        append(manifestFingerprint, to: &bytes)
        append(branch, to: &bytes)
        append(head, to: &bytes)
        append(worktreeFingerprint, to: &bytes)
        return sha256(bytes)
    }

    private static func append(_ value: String, to data: inout Data) {
        let encoded = Data(value.utf8)
        append(UInt64(encoded.count), to: &data)
        data.append(encoded)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
