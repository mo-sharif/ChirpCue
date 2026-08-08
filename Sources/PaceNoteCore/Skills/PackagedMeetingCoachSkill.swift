import CryptoKit
import Foundation

public enum PackagedMeetingCoachSkillError: Error, Equatable, Sendable {
    case resourceMissing
    case integrityMismatch
}

public struct PackagedMeetingCoachSkill: Sendable {
    public static let name = "pacenote-meeting-coach"

    public static let expectedSkillHash =
        "bd28c282bcc2021b1495d23c16e377557b13a5699005c7df47f15308f88d5db6"
    public static let expectedMetadataHash =
        "0cb4fd04ec760d0aa274ac3b499826bd8a4d4782a02674b94b49912815552b4c"

    public let directoryURL: URL
    public let skillURL: URL
    public let metadataURL: URL

    public init() throws {
        guard let resources = Bundle.module.resourceURL else {
            throw PackagedMeetingCoachSkillError.resourceMissing
        }

        let candidates = [
            resources
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Skills", isDirectory: true),
            resources.appendingPathComponent("Skills", isDirectory: true),
        ]
        guard
            let directory =
                candidates
                .map({ $0.appendingPathComponent(Self.name, isDirectory: true) })
                .first(where: {
                    FileManager.default.fileExists(
                        atPath: $0.appendingPathComponent("SKILL.md", isDirectory: false).path
                    )
                })
        else {
            throw PackagedMeetingCoachSkillError.resourceMissing
        }
        let skill = directory.appendingPathComponent("SKILL.md", isDirectory: false)
        let metadata =
            directory
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("openai.yaml", isDirectory: false)
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw PackagedMeetingCoachSkillError.resourceMissing
        }

        self.directoryURL = directory
        self.skillURL = skill
        self.metadataURL = metadata
    }

    public func verifyIntegrity() throws {
        try Self.verifyIntegrity(skillURL: skillURL, metadataURL: metadataURL)
    }

    static func verifyIntegrity(skillURL: URL, metadataURL: URL) throws {
        guard try hash(skillURL) == expectedSkillHash,
            try hash(metadataURL) == expectedMetadataHash
        else {
            throw PackagedMeetingCoachSkillError.integrityMismatch
        }
    }

    private static func hash(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
