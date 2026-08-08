import Foundation

public struct CodexIsolatedRuntime: Equatable, Sendable {
    public let profileRoot: URL
    public let configurationURL: URL
    public let permissionProfileID: String
    public let processArguments: [String]
    public let processEnvironment: [String: String]

    public init(
        profileRoot: URL,
        configurationURL: URL,
        permissionProfileID: String,
        processArguments: [String],
        processEnvironment: [String: String]
    ) {
        self.profileRoot = profileRoot
        self.configurationURL = configurationURL
        self.permissionProfileID = permissionProfileID
        self.processArguments = processArguments
        self.processEnvironment = processEnvironment
    }
}

public enum CodexIsolatedRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileRoot
    case invalidTemporaryRoot
    case invalidUserHome
    case invalidPermissionProfile
    case unsafeExistingConfiguration
    case credentialMaterialPresent(String)
    case cannotPrepareProfile

    public var errorDescription: String? {
        switch self {
        case .invalidProfileRoot:
            "The ChirpCue Codex profile root is invalid."
        case .invalidTemporaryRoot:
            "The ChirpCue Codex temporary directory is invalid."
        case .invalidUserHome:
            "ChirpCue could not resolve the signed-in macOS user's home directory for Keychain access."
        case .invalidPermissionProfile:
            "The ChirpCue Codex permission profile name is invalid."
        case .unsafeExistingConfiguration:
            "The ChirpCue Codex configuration path is not a regular private file."
        case .credentialMaterialPresent:
            "The ChirpCue Codex profile contains credential material outside the OS credential store."
        case .cannotPrepareProfile:
            "ChirpCue could not prepare its isolated Codex profile."
        }
    }
}

public enum CodexIsolatedRuntimeBuilder {
    public static let defaultPermissionProfileID = "pacenote-readonly"

    public static func prepare(
        profileRoot: URL,
        temporaryRoot: URL? = nil,
        permissionProfileID: String = defaultPermissionProfileID,
        codexExecutableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> CodexIsolatedRuntime {
        let root = profileRoot.standardizedFileURL
        guard root.isFileURL,
            root.path.hasPrefix("/"),
            !root.path.contains("\0")
        else {
            throw CodexIsolatedRuntimeError.invalidProfileRoot
        }
        guard
            permissionProfileID.range(
                of: #"^[A-Za-z][A-Za-z0-9_-]{2,63}$"#,
                options: .regularExpression
            ) != nil
        else {
            throw CodexIsolatedRuntimeError.invalidPermissionProfile
        }

        do {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue,
                    root.resolvingSymlinksInPath().standardizedFileURL == root
                else {
                    throw CodexIsolatedRuntimeError.invalidProfileRoot
                }
            } else {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

            for name in credentialEntryNames {
                let credentialURL = root.appendingPathComponent(name, isDirectory: false)
                if fileManager.fileExists(atPath: credentialURL.path) {
                    throw CodexIsolatedRuntimeError.credentialMaterialPresent(name)
                }
            }

            let temporaryDirectory = try prepareTemporaryRoot(
                temporaryRoot ?? root.appendingPathComponent("tmp", isDirectory: true),
                fileManager: fileManager
            )
            let homeDirectory = try validatedUserHomeDirectory(
                userHomeDirectory,
                isolatedProfileRoot: root,
                fileManager: fileManager
            )

            let configURL = root.appendingPathComponent("config.toml", isDirectory: false)
            if fileManager.fileExists(atPath: configURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    configURL.resolvingSymlinksInPath().standardizedFileURL == configURL
                else {
                    throw CodexIsolatedRuntimeError.unsafeExistingConfiguration
                }
            }

            let configuration = configurationText(permissionProfileID: permissionProfileID)
            try Data(configuration.utf8).write(to: configURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

            return CodexIsolatedRuntime(
                profileRoot: root,
                configurationURL: configURL,
                permissionProfileID: permissionProfileID,
                processArguments: ["app-server", "--strict-config", "--stdio"],
                processEnvironment: sanitizedEnvironment(
                    inheritedEnvironment,
                    profileRoot: root,
                    temporaryRoot: temporaryDirectory,
                    userHomeDirectory: homeDirectory,
                    codexExecutableURL: codexExecutableURL
                )
            )
        } catch let error as CodexIsolatedRuntimeError {
            throw error
        } catch {
            throw CodexIsolatedRuntimeError.cannotPrepareProfile
        }
    }

    public static func configurationText(permissionProfileID: String) -> String {
        """
        check_for_update_on_startup = false
        web_search = "disabled"
        default_permissions = "\(permissionProfileID)"
        cli_auth_credentials_store = "keyring"

        [analytics]
        enabled = false

        [history]
        persistence = "none"

        [agents]
        enabled = false

        [memories]
        generate_memories = false
        use_memories = false

        [features]
        hooks = false
        memories = false
        browser_use = false
        browser_use_external = false
        browser_use_full_cdp_access = false
        computer_use = false
        skill_mcp_dependency_install = false

        [apps._default]
        enabled = false
        destructive_enabled = false
        open_world_enabled = false

        [shell_environment_policy]
        inherit = "none"

        [permissions.\(permissionProfileID)]
        description = "ChirpCue sealed snapshot read-only"

        [permissions.\(permissionProfileID).filesystem]
        ":root" = "deny"
        ":minimal" = "read"
        ":tmpdir" = "deny"
        ":slash_tmp" = "deny"

        [permissions.\(permissionProfileID).filesystem.":workspace_roots"]
        "." = "read"
        "**/.env" = "deny"
        "**/.env.*" = "deny"
        "**/*.pem" = "deny"
        "**/*.key" = "deny"
        "**/*credential*" = "deny"
        "**/*secret*" = "deny"
        "**/*token*" = "deny"

        [permissions.\(permissionProfileID).network]
        enabled = false
        """ + "\n"
    }

    public static func sanitizedEnvironment(
        _ inherited: [String: String],
        profileRoot: URL,
        temporaryRoot: URL,
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexExecutableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
    ) -> [String: String] {
        let permittedKeys: Set<String> = [
            "LANG", "LC_ALL", "LC_CTYPE", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier", "SYSTEM_VERSION_COMPAT",
        ]
        let executableDirectory = codexExecutableURL.standardizedFileURL
            .deletingLastPathComponent().path
        let path = [executableDirectory, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        var result: [String: String] = [
            // Security.framework resolves the user's default Keychain relative to HOME.
            // CODEX_HOME still owns every Codex config/state path; only HOME retains the
            // canonical macOS user identity required for Keychain-backed ChatGPT auth.
            "HOME": userHomeDirectory.standardizedFileURL.path,
            "CODEX_HOME": profileRoot.path,
            "TMPDIR": temporaryRoot.path,
            "PATH": path,
        ]
        for (key, value) in inherited where permittedKeys.contains(key) {
            guard !value.contains("\0"), value.utf8.count <= 4_096 else { continue }
            result[key] = value
        }
        return result
    }

    private static func validatedUserHomeDirectory(
        _ userHomeDirectory: URL,
        isolatedProfileRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        let home = userHomeDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard home.isFileURL,
            home.path.hasPrefix("/"),
            !home.path.contains("\0"),
            home.path.utf8.count <= 4_096,
            home != isolatedProfileRoot,
            fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CodexIsolatedRuntimeError.invalidUserHome
        }
        return home
    }

    private static func prepareTemporaryRoot(
        _ temporaryRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        let root = temporaryRoot.standardizedFileURL
        guard root.isFileURL,
            root.path.hasPrefix("/"),
            !root.path.contains("\0")
        else {
            throw CodexIsolatedRuntimeError.invalidTemporaryRoot
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                root.resolvingSymlinksInPath().standardizedFileURL == root
            else {
                throw CodexIsolatedRuntimeError.invalidTemporaryRoot
            }
        } else {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private static let credentialEntryNames = [
        ".credentials.json", "auth.json", "credentials.json",
    ]
}
