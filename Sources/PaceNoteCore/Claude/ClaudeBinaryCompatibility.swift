import Darwin
import Foundation
import Security

public enum ClaudeBinaryCompatibilityError: Error, Equatable, LocalizedError, Sendable {
    case invalidUserHome
    case launcherUnavailable
    case untrustedExecutable
    case incompatibleBinaryVersion

    public var errorDescription: String? {
        switch self {
        case .invalidUserHome:
            "ChirpCue could not resolve the signed-in macOS user's home directory."
        case .launcherUnavailable:
            "The official user-local Claude launcher is unavailable."
        case .untrustedExecutable:
            "The installed Claude executable could not be verified as an official Anthropic build."
        case .incompatibleBinaryVersion:
            "The installed Claude version is outside ChirpCue's tested compatibility range."
        }
    }
}

public enum ClaudeBinaryAuthenticityValidator {
    public static let anthropicTeamIdentifier = "Q6L2SF6YDW"
    public static let claudeCodeSigningIdentifier = "com.anthropic.claude-code"

    public static func validate(_ executableURL: URL) throws {
        let executable = executableURL.standardizedFileURL
        let metadata = try? ClaudeFileTrustMetadata.read(executable)
        guard executable.isFileURL,
            executable.path.hasPrefix("/"),
            !executable.path.contains("\0"),
            executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            FileManager.default.isExecutableFile(atPath: executable.path),
            metadata?.isRegularFile == true,
            metadata?.ownerUserID == getuid(),
            metadata?.isGroupOrWorldWritable == false
        else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }

        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                executable as CFURL,
                SecCSFlags(),
                &staticCode
            ) == errSecSuccess,
            let staticCode
        else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }

        let requirementText =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(anthropicTeamIdentifier)\" "
            + "and identifier \"\(claudeCodeSigningIdentifier)\""
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                requirement
            ) == errSecSuccess
        else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
    }
}

public struct ClaudeExecutableTrustSnapshot: Equatable, Sendable {
    public let executableURL: URL
    private let metadata: ClaudeFileTrustMetadata

    public static func capture(_ executableURL: URL) throws -> ClaudeExecutableTrustSnapshot {
        try capture(
            executableURL,
            authenticityValidation: ClaudeBinaryAuthenticityValidator.validate
        )
    }

    static func capture(
        _ executableURL: URL,
        authenticityValidation: @Sendable (URL) throws -> Void
    ) throws -> ClaudeExecutableTrustSnapshot {
        let executable = executableURL.standardizedFileURL
        let metadata: ClaudeFileTrustMetadata
        do {
            metadata = try ClaudeFileTrustMetadata.read(executable)
            guard executable.resolvingSymlinksInPath().standardizedFileURL == executable,
                metadata.isRegularFile,
                metadata.ownerUserID == getuid(),
                !metadata.isGroupOrWorldWritable,
                FileManager.default.isExecutableFile(atPath: executable.path)
            else {
                throw ClaudeBinaryCompatibilityError.untrustedExecutable
            }
            try authenticityValidation(executable)
        } catch {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
        return ClaudeExecutableTrustSnapshot(
            executableURL: executable,
            metadata: metadata
        )
    }

    public func revalidate() throws {
        try revalidate(
            authenticityValidation: ClaudeBinaryAuthenticityValidator.validate
        )
    }

    func revalidate(
        authenticityValidation: @Sendable (URL) throws -> Void
    ) throws {
        let current = try Self.capture(
            executableURL,
            authenticityValidation: authenticityValidation
        )
        guard current.metadata == metadata else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
    }
}

public enum ClaudeOfficialLauncherResolver {
    public static func launcherURL(realHomeDirectory: URL) -> URL {
        realHomeDirectory.standardizedFileURL
            .appendingPathComponent(".local/bin/claude", isDirectory: false)
    }

    public static func resolve(
        launcherURL: URL? = nil,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        try resolve(
            launcherURL: launcherURL,
            realHomeDirectory: realHomeDirectory,
            fileManager: fileManager,
            authenticityValidation: ClaudeBinaryAuthenticityValidator.validate
        )
    }

    static func resolve(
        launcherURL: URL?,
        realHomeDirectory: URL,
        fileManager: FileManager,
        authenticityValidation: @Sendable (URL) throws -> Void
    ) throws -> URL {
        let home = realHomeDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard home.isFileURL,
            home.path.hasPrefix("/"),
            !home.path.contains("\0"),
            home.resolvingSymlinksInPath().standardizedFileURL == home,
            fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ClaudeBinaryCompatibilityError.invalidUserHome
        }

        let expectedLauncher = Self.launcherURL(realHomeDirectory: home)
        let launcher = (launcherURL ?? expectedLauncher).standardizedFileURL
        let launcherMetadata = try? ClaudeFileTrustMetadata.read(launcher)
        guard launcher == expectedLauncher,
            launcher.isFileURL,
            !launcher.path.contains("\0"),
            launcherMetadata?.isSymbolicLink == true,
            launcherMetadata?.ownerUserID == getuid()
        else {
            throw ClaudeBinaryCompatibilityError.launcherUnavailable
        }

        let versionsRoot =
            home
            .appendingPathComponent(".local/share/claude/versions", isDirectory: true)
            .standardizedFileURL
        let executable = launcher.resolvingSymlinksInPath().standardizedFileURL
        let versionsMetadata = try? ClaudeFileTrustMetadata.read(versionsRoot)
        let executableMetadata = try? ClaudeFileTrustMetadata.read(executable)
        let targetVersion = ClaudeBinaryVersion.parse(executable.lastPathComponent)
        guard versionsRoot.resolvingSymlinksInPath().standardizedFileURL == versionsRoot,
            versionsMetadata?.isDirectory == true,
            versionsMetadata?.ownerUserID == getuid(),
            versionsMetadata?.isGroupOrWorldWritable == false,
            executable != launcher,
            executable.deletingLastPathComponent() == versionsRoot,
            executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            let targetVersion,
            fileManager.isExecutableFile(atPath: executable.path),
            executableMetadata?.isRegularFile == true,
            executableMetadata?.ownerUserID == getuid(),
            executableMetadata?.isGroupOrWorldWritable == false
        else {
            throw ClaudeBinaryCompatibilityError.launcherUnavailable
        }
        try ClaudeVersionPolicy.tested.validate(targetVersion)

        do {
            try authenticityValidation(executable)
        } catch {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
        return executable
    }
}

public struct ClaudeBinaryVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public static func parse(_ output: String) -> ClaudeBinaryVersion? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard
            let token = tokens.first(where: { value in
                value.first?.isNumber == true && value.contains(".")
            })
        else {
            return nil
        }

        let versionAndPrerelease = token.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3,
            let major = Int(core[0]),
            let minor = Int(core[1]),
            let patch = Int(core[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else {
            return nil
        }

        let prerelease =
            versionAndPrerelease.count == 2
            ? String(versionAndPrerelease[1])
            : nil
        guard prerelease?.isEmpty != true else { return nil }
        return ClaudeBinaryVersion(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prerelease
        )
    }

    public static func < (lhs: ClaudeBinaryVersion, rhs: ClaudeBinaryVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        return switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): false
        case (.some, nil): true
        case (nil, .some): false
        case (.some(let left), .some(let right)): left < right
        }
    }
}

private struct ClaudeFileTrustMetadata: Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let ownerUserID: uid_t
    let permissions: mode_t
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let fileType: mode_t

    var isRegularFile: Bool { fileType == S_IFREG }
    var isDirectory: Bool { fileType == S_IFDIR }
    var isSymbolicLink: Bool { fileType == S_IFLNK }
    var isGroupOrWorldWritable: Bool {
        permissions & (S_IWGRP | S_IWOTH) != 0
    }

    static func read(_ url: URL) throws -> ClaudeFileTrustMetadata {
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            !url.path.contains("\0")
        else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
        return ClaudeFileTrustMetadata(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            ownerUserID: value.st_uid,
            permissions: value.st_mode & 0o7777,
            size: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            fileType: value.st_mode & S_IFMT
        )
    }
}

public struct ClaudeVersionPolicy: Equatable, Sendable {
    public let minimumCore: ClaudeBinaryVersion
    public let maximumCoreExclusive: ClaudeBinaryVersion
    public let permitsPrerelease: Bool

    public init(
        minimumCore: ClaudeBinaryVersion,
        maximumCoreExclusive: ClaudeBinaryVersion,
        permitsPrerelease: Bool
    ) {
        self.minimumCore = minimumCore
        self.maximumCoreExclusive = maximumCoreExclusive
        self.permitsPrerelease = permitsPrerelease
    }

    public static let tested = ClaudeVersionPolicy(
        minimumCore: .init(major: 2, minor: 1, patch: 218),
        maximumCoreExclusive: .init(major: 2, minor: 2, patch: 0),
        permitsPrerelease: false
    )

    public func validate(_ version: ClaudeBinaryVersion) throws {
        let core = ClaudeBinaryVersion(
            major: version.major,
            minor: version.minor,
            patch: version.patch
        )
        guard core >= minimumCore,
            core < maximumCoreExclusive,
            permitsPrerelease || version.prerelease == nil
        else {
            throw ClaudeBinaryCompatibilityError.incompatibleBinaryVersion
        }
    }
}

public enum ClaudeBinaryInspector {
    public static func inspect(
        executableURL: URL,
        environment: [String: String]? = nil
    ) async throws -> ClaudeBinaryVersion {
        let executable = executableURL.standardizedFileURL
        guard executable.isFileURL,
            executable.path.hasPrefix("/"),
            executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }

        do {
            let result = try await BoundedProcessRunner.run(
                executableURL: executable,
                arguments: ["--version"],
                environment: environment,
                limits: .init(
                    timeout: .seconds(2),
                    standardOutputBytes: 4_096,
                    standardErrorBytes: 4_096
                )
            )
            guard result.terminationStatus == 0,
                let output = String(data: result.standardOutput, encoding: .utf8),
                let version = ClaudeBinaryVersion.parse(output),
                let targetVersion = ClaudeBinaryVersion.parse(executable.lastPathComponent),
                version == targetVersion
            else {
                throw ClaudeBinaryCompatibilityError.untrustedExecutable
            }
            try ClaudeVersionPolicy.tested.validate(version)
            return version
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeBinaryCompatibilityError {
            throw error
        } catch {
            throw ClaudeBinaryCompatibilityError.untrustedExecutable
        }
    }
}
