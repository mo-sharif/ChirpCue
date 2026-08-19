import Foundation

enum CodexProfileForgetError: Error, Equatable, Sendable {
    case invalidProfileRoot
    case profileReplacementFailed
    case credentialStoreLogoutFailed
}

struct CodexProfileForgetter: @unchecked Sendable {
    let applicationRoot: URL
    let profileRoot: URL
    let fileManager: FileManager

    init(
        applicationRoot: URL,
        profileRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.applicationRoot = applicationRoot.standardizedFileURL
        self.profileRoot = profileRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    func forget(
        logoutFromCleanProfile: @Sendable () async throws -> Void
    ) async throws {
        try validateProfileLocation()

        do {
            try replaceWithEmptyPrivateDirectory()
        } catch {
            throw CodexProfileForgetError.profileReplacementFailed
        }

        var logoutFailed = false
        do {
            try await logoutFromCleanProfile()
        } catch {
            logoutFailed = true
        }

        do {
            try replaceWithEmptyPrivateDirectory()
        } catch {
            throw CodexProfileForgetError.profileReplacementFailed
        }
        if logoutFailed {
            throw CodexProfileForgetError.credentialStoreLogoutFailed
        }
    }

    /// Rebuilds only ChirpCue's isolated on-disk Codex profile. ChatGPT authentication
    /// remains in the macOS Keychain and is deliberately not logged out.
    func resetLocalProfileForRecovery() throws {
        do {
            try replaceWithEmptyPrivateDirectory()
        } catch {
            throw CodexProfileForgetError.profileReplacementFailed
        }
    }

    private func replaceWithEmptyPrivateDirectory() throws {
        try validateProfileLocation()
        let values = try? profileRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        if fileManager.fileExists(atPath: profileRoot.path)
            || values?.isSymbolicLink == true
        {
            try fileManager.removeItem(at: profileRoot)
        }
        try validateProfileLocation()
        try fileManager.createDirectory(
            at: profileRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: profileRoot.path
        )
    }

    private func validateProfileLocation() throws {
        let rootPath = applicationRoot.path
        let parent = profileRoot.deletingLastPathComponent().standardizedFileURL
        guard profileRoot.path.hasPrefix(rootPath + "/"),
            parent.path.hasPrefix(rootPath + "/"),
            applicationRoot.resolvingSymlinksInPath().standardizedFileURL == applicationRoot
        else {
            throw CodexProfileForgetError.invalidProfileRoot
        }

        let relativeParent = String(parent.path.dropFirst(rootPath.count + 1))
        var current = applicationRoot
        for component in relativeParent.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            var isDirectory: ObjCBool = false
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                values?.isSymbolicLink != true,
                current.resolvingSymlinksInPath().standardizedFileURL == current.standardizedFileURL
            else {
                throw CodexProfileForgetError.invalidProfileRoot
            }
        }
    }
}
