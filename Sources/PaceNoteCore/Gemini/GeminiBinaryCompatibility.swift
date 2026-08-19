import Darwin
import Foundation
import Security

public enum GeminiBinaryCompatibilityError: Error, Equatable, LocalizedError, Sendable {
    case invalidUserHome
    case launcherUnavailable
    case untrustedExecutable
    case incompatibleBinaryVersion

    public var errorDescription: String? {
        switch self {
        case .invalidUserHome:
            "ChirpCue could not resolve the signed-in macOS user's home directory."
        case .launcherUnavailable:
            "Install the official Google Antigravity CLI before using Gemini."
        case .untrustedExecutable:
            "The installed Google Antigravity executable could not be verified as an official Google build."
        case .incompatibleBinaryVersion:
            "The installed Google Antigravity version is outside ChirpCue's tested compatibility range."
        }
    }
}

public enum GeminiBinaryAuthenticityValidator {
    public static let googleTeamIdentifier = "EQHXZ8M8AV"
    public static let signingIdentifier = "cli"

    public static func validate(_ executableURL: URL) throws {
        let executable = executableURL.standardizedFileURL
        let metadata = try? GeminiFileTrustMetadata.read(executable)
        guard executable.isFileURL,
            executable.path.hasPrefix("/"),
            !executable.path.contains("\0"),
            executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            FileManager.default.isExecutableFile(atPath: executable.path),
            metadata?.isRegularFile == true,
            metadata?.ownerUserID == getuid(),
            metadata?.isGroupOrWorldWritable == false
        else {
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }

        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &staticCode)
                == errSecSuccess,
            let staticCode
        else {
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }

        let requirementText =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(googleTeamIdentifier)\" "
            + "and identifier \"\(signingIdentifier)\""
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
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }
    }
}

public struct GeminiExecutableTrustSnapshot: Equatable, Sendable {
    public let executableURL: URL
    private let metadata: GeminiFileTrustMetadata

    public static func capture(_ executableURL: URL) throws -> GeminiExecutableTrustSnapshot {
        try capture(
            executableURL,
            authenticityValidation: GeminiBinaryAuthenticityValidator.validate
        )
    }

    static func capture(
        _ executableURL: URL,
        authenticityValidation: @Sendable (URL) throws -> Void
    ) throws -> GeminiExecutableTrustSnapshot {
        let executable = executableURL.standardizedFileURL
        let metadata = try GeminiFileTrustMetadata.read(executable)
        guard executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            metadata.isRegularFile,
            metadata.ownerUserID == getuid(),
            !metadata.isGroupOrWorldWritable,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }
        try authenticityValidation(executable)
        return GeminiExecutableTrustSnapshot(executableURL: executable, metadata: metadata)
    }

    public func revalidate() throws {
        let current = try Self.capture(executableURL)
        guard current.metadata == metadata else {
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }
    }
}

public enum GeminiOfficialLauncherResolver {
    public static func launcherURL(realHomeDirectory: URL) -> URL {
        realHomeDirectory.standardizedFileURL
            .appendingPathComponent(".local/bin/agy", isDirectory: false)
    }

    public static func resolve(
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        authenticityValidation: @Sendable (URL) throws -> Void =
            GeminiBinaryAuthenticityValidator.validate
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
            throw GeminiBinaryCompatibilityError.invalidUserHome
        }

        let executable = launcherURL(realHomeDirectory: home)
        let metadata = try? GeminiFileTrustMetadata.read(executable)
        guard executable.resolvingSymlinksInPath().standardizedFileURL == executable,
            metadata?.isRegularFile == true,
            metadata?.ownerUserID == getuid(),
            metadata?.isGroupOrWorldWritable == false,
            fileManager.isExecutableFile(atPath: executable.path)
        else {
            throw GeminiBinaryCompatibilityError.launcherUnavailable
        }
        try authenticityValidation(executable)
        return executable
    }
}

public struct GeminiBinaryVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(_ output: String) -> GeminiBinaryVersion? {
        let token = output.split(whereSeparator: { $0.isWhitespace }).first
        let parts = token?.split(separator: ".", omittingEmptySubsequences: false)
        guard parts?.count == 3,
            let parts,
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else {
            return nil
        }
        return GeminiBinaryVersion(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: GeminiBinaryVersion, rhs: GeminiBinaryVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct GeminiVersionPolicy: Equatable, Sendable {
    public let minimumInclusive: GeminiBinaryVersion
    public let maximumExclusive: GeminiBinaryVersion

    public static let tested = GeminiVersionPolicy(
        minimumInclusive: .init(major: 1, minor: 1, patch: 12),
        maximumExclusive: .init(major: 1, minor: 2, patch: 0)
    )

    public func validate(_ version: GeminiBinaryVersion) throws {
        guard version >= minimumInclusive, version < maximumExclusive else {
            throw GeminiBinaryCompatibilityError.incompatibleBinaryVersion
        }
    }
}

public enum GeminiBinaryInspector {
    public static func inspect(
        executableURL: URL,
        currentDirectoryURL: URL,
        environment: [String: String],
        runner: any ClaudeCommandRunning = ClaudeProcessRunner()
    ) async throws -> GeminiBinaryVersion {
        let result = try await runner.run(
            ClaudeCommandRequest(
                executableURL: executableURL,
                currentDirectoryURL: currentDirectoryURL,
                arguments: ["--version"],
                environment: environment,
                limits: ClaudeCommandLimits(
                    timeout: .seconds(5),
                    maximumStandardInputBytes: 0,
                    maximumStandardOutputBytes: 4 * 1_024,
                    maximumStandardErrorBytes: 4 * 1_024,
                    terminationGracePeriod: .milliseconds(500)
                )
            )
        )
        guard result.terminationStatus == 0,
            let output = String(data: result.standardOutput, encoding: .utf8),
            let version = GeminiBinaryVersion.parse(output)
        else {
            throw GeminiBinaryCompatibilityError.incompatibleBinaryVersion
        }
        return version
    }
}

private struct GeminiFileTrustMetadata: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let ownerUserID: uid_t
    let mode: mode_t
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }
    var isGroupOrWorldWritable: Bool { (mode & (S_IWGRP | S_IWOTH)) != 0 }

    static func read(_ url: URL) throws -> GeminiFileTrustMetadata {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw GeminiBinaryCompatibilityError.untrustedExecutable
        }
        return GeminiFileTrustMetadata(
            device: UInt64(status.st_dev),
            inode: status.st_ino,
            ownerUserID: status.st_uid,
            mode: status.st_mode,
            size: status.st_size,
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }
}
