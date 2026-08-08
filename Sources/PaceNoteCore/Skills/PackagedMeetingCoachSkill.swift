import CryptoKit
import Foundation

public enum PackagedMeetingCoachSkillError: Error, Equatable, Sendable {
    case resourceMissing
    case integrityMismatch
}

public struct PackagedMeetingCoachSkill: Sendable {
    public static let name = "pacenote-meeting-coach"

    public static let expectedSkillHash =
        "79d00fac8c5c01f1c0e9216e7864355a88a2e6db4b970e98ce4f041935db3269"
    public static let expectedMetadataHash =
        "42d8729a9b32fa85b97845efbfa1dc6e5359780bec5161680b858b7fdeada4aa"

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
