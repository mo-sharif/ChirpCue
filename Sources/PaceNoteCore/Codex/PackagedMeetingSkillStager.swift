import Foundation

enum PackagedMeetingSkillStager {
    static func contextRoot(in privateRoot: URL) -> URL {
        privateRoot.standardizedFileURL
            .appendingPathComponent("skill-context", isDirectory: true)
    }

    static func destination(in privateRoot: URL) -> URL {
        contextRoot(in: privateRoot)
            .appendingPathComponent(PackagedMeetingCoachSkill.name, isDirectory: true)
    }

    static func prepare(in privateRoot: URL, fileManager: FileManager = .default) throws -> URL {
        let packaged: PackagedMeetingCoachSkill
        do {
            packaged = try PackagedMeetingCoachSkill()
            try packaged.verifyIntegrity()
        } catch {
            throw MeetingResponseError.skillPolicyMismatch
        }

        let destination = destination(in: privateRoot)
        let metadataDirectory = destination.appendingPathComponent("agents", isDirectory: true)
        let skillURL = destination.appendingPathComponent("SKILL.md", isDirectory: false)
        let metadataURL = metadataDirectory.appendingPathComponent("openai.yaml", isDirectory: false)

        do {
            try fileManager.createDirectory(
                at: metadataDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metadataDirectory.path)

            try Data(contentsOf: packaged.skillURL, options: .mappedIfSafe)
                .write(to: skillURL, options: [.atomic])
            try Data(contentsOf: packaged.metadataURL, options: .mappedIfSafe)
                .write(to: metadataURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: skillURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            try PackagedMeetingCoachSkill.verifyIntegrity(
                skillURL: skillURL,
                metadataURL: metadataURL
            )
            return destination
        } catch {
            throw MeetingResponseError.skillPolicyMismatch
        }
    }
}
