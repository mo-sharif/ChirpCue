import Darwin
import Foundation
import Security

struct BoundedProcessLimits: Sendable {
    let timeout: Duration
    let standardOutputBytes: Int
    let standardErrorBytes: Int
    let terminationGracePeriod: Duration

    init(
        timeout: Duration,
        standardOutputBytes: Int,
        standardErrorBytes: Int,
        terminationGracePeriod: Duration = .milliseconds(250)
    ) {
        self.timeout = timeout
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
        self.terminationGracePeriod = terminationGracePeriod
    }
}

struct BoundedProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
}

enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        limits: BoundedProcessLimits
    ) async throws -> BoundedProcessResult {
        let controller = BoundedProcessController()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try controller.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    limits: limits
                )
            }.value
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class BoundedProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    func cancel() {
        lock.withLock { cancellationRequested = true }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        limits: BoundedProcessLimits
    ) throws -> BoundedProcessResult {
        guard limits.standardOutputBytes >= 0,
            limits.standardErrorBytes >= 0,
            limits.timeout > .zero,
            limits.terminationGracePeriod >= .zero
        else {
            throw BoundedProcessError.launchFailed
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors

        let outputCollector = BoundedPipeCollector(limit: limits.standardOutputBytes)
        let errorCollector = BoundedPipeCollector(limit: limits.standardErrorBytes)
        let drainGroup = DispatchGroup()

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed
        }

        // Close the parent's copies of the write ends so both readers receive EOF
        // as soon as the child exits.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        Self.drain(
            output.fileHandleForReading,
            into: outputCollector,
            group: drainGroup
        )
        Self.drain(
            errors.fileHandleForReading,
            into: errorCollector,
            group: drainGroup
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limits.timeout)
        var terminalError: (any Error)?
        while process.isRunning {
            if isCancellationRequested {
                terminalError = CancellationError()
                break
            }
            if outputCollector.didExceedLimit || errorCollector.didExceedLimit {
                terminalError = BoundedProcessError.outputLimitExceeded
                break
            }
            if clock.now >= deadline {
                terminalError = BoundedProcessError.timedOut
                break
            }
            usleep(10_000)
        }

        if terminalError != nil {
            Self.terminateAndReap(
                process,
                gracePeriod: limits.terminationGracePeriod,
                clock: clock
            )
        } else {
            process.waitUntilExit()
        }

        // A well-behaved child closes both descriptors at exit. If a descendant
        // inherited one, close our read side after a bounded grace period so the
        // probe itself can never hang while draining.
        if drainGroup.wait(timeout: .now() + 1) == .timedOut {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            drainGroup.wait()
        }

        if isCancellationRequested {
            throw CancellationError()
        }
        if let terminalError {
            throw terminalError
        }
        guard !outputCollector.didExceedLimit,
            !errorCollector.didExceedLimit
        else {
            throw BoundedProcessError.outputLimitExceeded
        }
        return BoundedProcessResult(
            standardOutput: outputCollector.data,
            standardError: errorCollector.data,
            terminationStatus: process.terminationStatus
        )
    }

    private var isCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    private static func drain(
        _ handle: FileHandle,
        into collector: BoundedPipeCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty else {
                        return
                    }
                    collector.append(chunk)
                } catch {
                    return
                }
            }
        }
    }

    private static func terminateAndReap(
        _ process: Process,
        gracePeriod: Duration,
        clock: ContinuousClock
    ) {
        if process.isRunning {
            process.terminate()
            let deadline = clock.now.advanced(by: gracePeriod)
            while process.isRunning, clock.now < deadline {
                usleep(10_000)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 64 * 1_024))
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            if remaining > 0 {
                storage.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                exceeded = true
            }
        }
    }

    var data: Data {
        lock.withLock { storage }
    }

    var didExceedLimit: Bool {
        lock.withLock { exceeded }
    }
}

public enum CodexBinaryAuthenticityValidator {
    public static let openAITeamIdentifier = "2DC432GLL2"
    public static let codexSigningIdentifier = "codex"

    private static let officialExecutablePaths: Set<String> = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    public static func validate(_ executableURL: URL) throws {
        let standardized = executableURL.standardizedFileURL
        guard standardized.isFileURL,
            officialExecutablePaths.contains(standardized.path),
            standardized.resolvingSymlinksInPath().standardizedFileURL == standardized,
            FileManager.default.isExecutableFile(atPath: standardized.path)
        else {
            throw CodexClientError.binaryUnavailable
        }

        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                standardized as CFURL,
                SecCSFlags(),
                &staticCode
            ) == errSecSuccess,
            let staticCode
        else {
            throw CodexClientError.binaryUnavailable
        }

        let requirementText =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(openAITeamIdentifier)\" "
            + "and identifier \"\(codexSigningIdentifier)\""
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
            throw CodexClientError.binaryUnavailable
        }
    }
}

public enum CodexChatGPTLoginURLPolicy {
    private static let allowedHosts: Set<String> = [
        "auth.openai.com",
        "chatgpt.com",
        "www.chatgpt.com",
    ]

    public static func permits(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443
        else {
            return false
        }
        return true
    }
}

public struct CodexBinaryVersion: Equatable, Comparable, Sendable {
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

    public static func parse(_ output: String) -> CodexBinaryVersion? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard
            let versionToken = tokens.first(where: { token in
                token.first?.isNumber == true && token.contains(".")
            })
        else {
            return nil
        }

        let versionAndPrerelease = versionToken.split(separator: "-", maxSplits: 1)
        let core = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
            let major = Int(core[0]),
            let minor = Int(core[1]),
            let patch = Int(core[2])
        else {
            return nil
        }

        let prerelease =
            versionAndPrerelease.count == 2
            ? String(versionAndPrerelease[1])
            : nil
        return CodexBinaryVersion(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prerelease
        )
    }

    public static func < (lhs: CodexBinaryVersion, rhs: CodexBinaryVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let left), .some(let right)): return left < right
        }
    }
}

public struct CodexVersionPolicy: Equatable, Sendable {
    public let minimumCore: CodexBinaryVersion
    public let maximumCoreExclusive: CodexBinaryVersion?
    public let permitsPrerelease: Bool

    public init(
        minimumCore: CodexBinaryVersion,
        maximumCoreExclusive: CodexBinaryVersion? = nil,
        permitsPrerelease: Bool
    ) {
        self.minimumCore = minimumCore
        self.maximumCoreExclusive = maximumCoreExclusive
        self.permitsPrerelease = permitsPrerelease
    }

    /// Accepts newer official Codex builds while retaining the minimum protocol floor.
    /// Runtime capability, permission-profile, and wire-contract checks remain fail closed.
    public static let supported = CodexVersionPolicy(
        minimumCore: .init(major: 0, minor: 147, patch: 0),
        permitsPrerelease: true
    )

    /// Source-compatible alias for callers built against the former bounded policy.
    public static let tested = supported

    public func validate(_ version: CodexBinaryVersion) throws {
        let core = CodexBinaryVersion(
            major: version.major,
            minor: version.minor,
            patch: version.patch
        )
        let isBelowMaximum = maximumCoreExclusive.map { core < $0 } ?? true
        guard core >= minimumCore,
            isBelowMaximum,
            permitsPrerelease || version.prerelease == nil
        else {
            throw CodexClientError.incompatibleBinaryVersion
        }
    }
}

public enum CodexBinaryInspector {
    public static func inspect(
        executableURL: URL,
        environment: [String: String]? = nil
    ) async throws -> CodexBinaryVersion {
        guard executableURL.isFileURL,
            executableURL.path.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw CodexClientError.binaryUnavailable
        }

        do {
            let result = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: ["--version"],
                environment: environment,
                limits: .init(
                    timeout: .seconds(2),
                    standardOutputBytes: 4_096,
                    standardErrorBytes: 4_096
                )
            )
            guard result.terminationStatus == 0,
                let outputString = String(data: result.standardOutput, encoding: .utf8),
                let version = CodexBinaryVersion.parse(outputString)
            else {
                throw CodexClientError.binaryUnavailable
            }
            return version
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexClientError.binaryUnavailable
        }
    }
}

public enum CodexRuntimeCapabilityInspector {
    public static func probe(
        executableURL: URL,
        environment: [String: String]? = nil
    ) async -> CodexRuntimeCapabilities {
        do {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("pacenote-codex-schema-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: directory) }

            let result = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: [
                    "app-server",
                    "generate-json-schema",
                    "--experimental",
                    "--out",
                    directory.path,
                ],
                environment: environment,
                limits: .init(
                    timeout: .seconds(5),
                    standardOutputBytes: 64 * 1_024,
                    standardErrorBytes: 64 * 1_024
                )
            )
            guard result.terminationStatus == 0 else {
                return .none
            }

            let schemaURL = directory.appendingPathComponent(
                "codex_app_server_protocol.v2.schemas.json"
            )
            return capabilities(
                in: try BoundedRegularFileReader.read(
                    schemaURL,
                    maximumBytes: 32 * 1_024 * 1_024
                )
            )
        } catch {
            // Realtime is optional. Any probe failure must select the stable turn fallback.
            return .none
        }
    }

    static func capabilities(in schemaData: Data) -> CodexRuntimeCapabilities {
        guard let schema = try? JSONDecoder().decode(JSONValue.self, from: schemaData),
            let definitions = schema["definitions"]?.objectValue
        else {
            return .none
        }

        let requestMethods = methods(in: definitions["ClientRequest"])
        let notificationMethods = methods(in: definitions["ServerNotification"])
        let startProperties = definitions["ThreadRealtimeStartParams"]?["properties"]?.objectValue
        let versions = enumStrings(in: definitions["RealtimeConversationVersion"])
        let modalities = enumStrings(in: definitions["RealtimeOutputModality"])

        let requiredRequests: Set<String> = [
            "thread/realtime/start",
            "thread/realtime/appendText",
            "thread/realtime/stop",
        ]
        let requiredNotifications: Set<String> = [
            "thread/realtime/started",
            "thread/realtime/itemAdded",
            "thread/realtime/transcript/delta",
            "thread/realtime/transcript/done",
            "thread/realtime/error",
            "thread/realtime/closed",
        ]
        let requiredStartProperties: Set<String> = [
            "threadId",
            "clientManagedHandoffs",
            "outputModality",
            "prompt",
            "version",
        ]

        let startPropertyNames = Set(startProperties?.keys.map { $0 } ?? [])
        return CodexRuntimeCapabilities(
            realtimeTextV3: requestMethods.isSuperset(of: requiredRequests)
                && notificationMethods.isSuperset(of: requiredNotifications)
                && startPropertyNames.isSuperset(of: requiredStartProperties)
                && versions.contains("v3")
                && modalities.contains("text")
        )
    }

    private static func methods(in definition: JSONValue?) -> Set<String> {
        guard let variants = definition?["oneOf"]?.arrayValue else { return [] }
        return Set(
            variants.compactMap { variant in
                variant["properties"]?["method"]?["enum"]?.arrayValue?.first?.stringValue
            })
    }

    private static func enumStrings(in definition: JSONValue?) -> Set<String> {
        Set(definition?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

private enum BoundedRegularFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size >= 0,
            metadata.st_size <= maximumBytes
        else {
            throw CocoaError(.fileReadTooLarge)
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard data.count <= maximumBytes - count else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(buffer, count: count)
        }
    }
}
