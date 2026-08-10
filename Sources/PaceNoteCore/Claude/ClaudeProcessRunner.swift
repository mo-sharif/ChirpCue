import Darwin
import Foundation

public struct ClaudeCommandLimits: Equatable, Sendable {
    public let timeout: Duration
    public let maximumStandardInputBytes: Int
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let terminationGracePeriod: Duration

    public init(
        timeout: Duration = .seconds(25),
        maximumStandardInputBytes: Int = 32 * 1_024,
        maximumStandardOutputBytes: Int = 256 * 1_024,
        maximumStandardErrorBytes: Int = 32 * 1_024,
        terminationGracePeriod: Duration = .milliseconds(500)
    ) {
        self.timeout = timeout
        self.maximumStandardInputBytes = maximumStandardInputBytes
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.terminationGracePeriod = terminationGracePeriod
    }
}

public struct ClaudeCommandRequest: Sendable {
    public let executableURL: URL
    public let currentDirectoryURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let standardInput: Data
    public let limits: ClaudeCommandLimits
    public let postLaunchValidator: @Sendable (pid_t, URL) throws -> Void

    public init(
        executableURL: URL,
        currentDirectoryURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data = Data(),
        limits: ClaudeCommandLimits = .init(),
        postLaunchValidator: @escaping @Sendable (pid_t, URL) throws -> Void = { _, _ in }
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.limits = limits
        self.postLaunchValidator = postLaunchValidator
    }
}

public struct ClaudeCommandResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32

    public init(
        standardOutput: Data,
        standardError: Data,
        terminationStatus: Int32
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }
}

public enum ClaudeCommandError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidRequest
    case launchFailed
    case timedOut
    case inputLimitExceeded
    case outputLimitExceeded
}

public protocol ClaudeCommandRunning: Sendable {
    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult
    func cancelActive() async
}

public actor ClaudeProcessRunner: ClaudeCommandRunning {
    private var activeController: ClaudeProcessController?

    public init() {}

    public func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        guard activeController == nil else { throw ClaudeCommandError.alreadyRunning }
        let controller = ClaudeProcessController()
        activeController = controller
        defer { activeController = nil }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try controller.run(request)
            }.value
        } onCancel: {
            controller.cancel()
        }
    }

    public func cancelActive() async {
        activeController?.cancel()
    }
}

private final class ClaudeProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var activeProcessGroupID: pid_t?

    func cancel() {
        let processGroupID = lock.withLock { () -> pid_t? in
            cancellationRequested = true
            return activeProcessGroupID
        }
        if let processGroupID {
            Self.signalProcessGroup(processGroupID, signal: SIGTERM)
        }
    }

    func run(_ request: ClaudeCommandRequest) throws -> ClaudeCommandResult {
        guard request.executableURL.isFileURL,
            request.executableURL.path.hasPrefix("/"),
            request.currentDirectoryURL.isFileURL,
            request.currentDirectoryURL.path.hasPrefix("/"),
            request.arguments.allSatisfy({ !$0.contains("\0") }),
            request.environment.allSatisfy({
                !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
                    && !$0.value.contains("\0")
            }),
            request.limits.timeout > .zero,
            request.limits.maximumStandardInputBytes >= 0,
            request.limits.maximumStandardOutputBytes >= 0,
            request.limits.maximumStandardErrorBytes >= 0,
            request.limits.terminationGracePeriod >= .zero
        else {
            throw ClaudeCommandError.invalidRequest
        }
        guard request.standardInput.count <= request.limits.maximumStandardInputBytes else {
            throw ClaudeCommandError.inputLimitExceeded
        }
        try requireNotCancelled()

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        let outputCollector = ClaudeBoundedDataCollector(
            limit: request.limits.maximumStandardOutputBytes
        )
        let errorCollector = ClaudeBoundedDataCollector(
            limit: request.limits.maximumStandardErrorBytes
        )
        let ioGroup = DispatchGroup()

        let processID: pid_t
        do {
            try requireNotCancelled()
            processID = try Self.spawn(
                request,
                standardInput: input.fileHandleForReading.fileDescriptor,
                standardOutput: output.fileHandleForWriting.fileDescriptor,
                standardError: errors.fileHandleForWriting.fileDescriptor,
                descriptorsToClose: [
                    input.fileHandleForWriting.fileDescriptor,
                    output.fileHandleForReading.fileDescriptor,
                    errors.fileHandleForReading.fileDescriptor,
                ]
            )
        } catch is CancellationError {
            Self.closeAll(input: input, output: output, errors: errors)
            throw CancellationError()
        } catch {
            Self.closeAll(input: input, output: output, errors: errors)
            throw ClaudeCommandError.launchFailed
        }

        let cancellationWasRequested = lock.withLock { () -> Bool in
            activeProcessGroupID = processID
            return cancellationRequested
        }
        defer {
            lock.withLock {
                if activeProcessGroupID == processID { activeProcessGroupID = nil }
            }
        }
        if cancellationWasRequested {
            Self.signalProcessGroup(processID, signal: SIGTERM)
        }

        do {
            try request.postLaunchValidator(processID, request.executableURL)
        } catch {
            var waitStatus: Int32 = 0
            _ = Self.terminateProcessGroupAndReapLeader(
                processID: processID,
                processGroupID: processID,
                didReapLeader: false,
                waitStatus: &waitStatus,
                gracePeriod: request.limits.terminationGracePeriod,
                clock: ContinuousClock()
            )
            Self.closeAll(input: input, output: output, errors: errors)
            throw ClaudeCommandError.launchFailed
        }

        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        Self.drain(output.fileHandleForReading, into: outputCollector, group: ioGroup)
        Self.drain(errors.fileHandleForReading, into: errorCollector, group: ioGroup)
        Self.write(
            request.standardInput,
            to: input.fileHandleForWriting,
            group: ioGroup
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: request.limits.timeout)
        var terminalError: (any Error)?
        var waitStatus: Int32 = 0
        var didReapLeader = false
        while !didReapLeader {
            let waitResult = Darwin.waitpid(processID, &waitStatus, WNOHANG)
            if waitResult == processID {
                didReapLeader = true
                break
            }
            if waitResult == -1, errno != EINTR {
                terminalError = ClaudeCommandError.launchFailed
                break
            }
            if isCancellationRequested {
                terminalError = CancellationError()
                break
            }
            if outputCollector.didExceedLimit || errorCollector.didExceedLimit {
                terminalError = ClaudeCommandError.outputLimitExceeded
                break
            }
            if clock.now >= deadline {
                terminalError = ClaudeCommandError.timedOut
                break
            }
            usleep(10_000)
        }

        if terminalError != nil || Self.processGroupExists(processID) {
            didReapLeader = Self.terminateProcessGroupAndReapLeader(
                processID: processID,
                processGroupID: processID,
                didReapLeader: didReapLeader,
                waitStatus: &waitStatus,
                gracePeriod: request.limits.terminationGracePeriod,
                clock: clock
            )
        }

        try? input.fileHandleForWriting.close()
        if ioGroup.wait(timeout: .now() + 1) == .timedOut {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            _ = ioGroup.wait(timeout: .now() + 1)
        }

        if isCancellationRequested { throw CancellationError() }
        if let terminalError { throw terminalError }
        guard didReapLeader else { throw ClaudeCommandError.launchFailed }
        guard !outputCollector.didExceedLimit, !errorCollector.didExceedLimit else {
            throw ClaudeCommandError.outputLimitExceeded
        }
        return ClaudeCommandResult(
            standardOutput: outputCollector.data,
            standardError: errorCollector.data,
            terminationStatus: Self.terminationStatus(from: waitStatus)
        )
    }

    private var isCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    private func requireNotCancelled() throws {
        if isCancellationRequested { throw CancellationError() }
    }

    private static func write(_ data: Data, to handle: FileHandle, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? handle.close()
                group.leave()
            }
            var sensitive = data
            defer {
                sensitive.resetBytes(in: sensitive.startIndex..<sensitive.endIndex)
                sensitive.removeAll(keepingCapacity: false)
            }
            do {
                try handle.write(contentsOf: sensitive)
            } catch {
                // The child may close stdin on cancellation or early failure. The exit path owns
                // the user-visible result, so stdin errors are intentionally not retained.
            }
        }
    }

    private static func drain(
        _ handle: FileHandle,
        into collector: ClaudeBoundedDataCollector,
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

    private static func spawn(
        _ request: ClaudeCommandRequest,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        descriptorsToClose: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ClaudeCommandError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let duplicateActions = [
            (standardInput, STDIN_FILENO),
            (standardOutput, STDOUT_FILENO),
            (standardError, STDERR_FILENO),
        ]
        for (source, destination) in duplicateActions {
            guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
                throw ClaudeCommandError.launchFailed
            }
        }
        let inheritedDescriptors = Set(
            duplicateActions.map(\.0) + descriptorsToClose
        ).filter { ![STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains($0) }
        for descriptor in inheritedDescriptors {
            guard posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0 else {
                throw ClaudeCommandError.launchFailed
            }
        }
        let changeDirectoryResult = request.currentDirectoryURL.path.withCString { path in
            posix_spawn_file_actions_addchdir(&fileActions, path)
        }
        guard changeDirectoryResult == 0 else { throw ClaudeCommandError.launchFailed }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ClaudeCommandError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw ClaudeCommandError.launchFailed
        }

        let arguments = [request.executableURL.path] + request.arguments
        let environment = request.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let spawnResult = Self.withMutableCStringArray(arguments) { argumentVector in
            Self.withMutableCStringArray(environment) { environmentVector in
                request.executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }
        guard spawnResult == 0, processID > 0 else {
            throw ClaudeCommandError.launchFailed
        }
        return processID
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func terminateProcessGroupAndReapLeader(
        processID: pid_t,
        processGroupID: pid_t,
        didReapLeader: Bool,
        waitStatus: inout Int32,
        gracePeriod: Duration,
        clock: ContinuousClock
    ) -> Bool {
        var reaped = didReapLeader
        Self.signalProcessGroup(processGroupID, signal: SIGTERM)
        let boundedGracePeriod = min(gracePeriod, .seconds(2))
        let gracefulDeadline = clock.now.advanced(by: boundedGracePeriod)
        while clock.now < gracefulDeadline {
            reaped = reapLeaderIfExited(processID, status: &waitStatus) || reaped
            if reaped, !processGroupExists(processGroupID) { return true }
            usleep(10_000)
        }

        Self.signalProcessGroup(processGroupID, signal: SIGKILL)
        let forcedDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < forcedDeadline {
            reaped = reapLeaderIfExited(processID, status: &waitStatus) || reaped
            if reaped, !processGroupExists(processGroupID) { return true }
            usleep(10_000)
        }
        return reaped
    }

    private static func reapLeaderIfExited(_ processID: pid_t, status: inout Int32) -> Bool {
        while true {
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID || (result == -1 && errno == ECHILD) { return true }
            if result == -1, errno == EINTR { continue }
            return false
        }
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 0 else { return false }
        if Darwin.killpg(processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) {
        guard processGroupID > 0 else { return }
        _ = Darwin.killpg(processGroupID, signal)
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 { return (waitStatus >> 8) & 0xff }
        return terminatingSignal
    }

    private static func closeAll(input: Pipe, output: Pipe, errors: Pipe) {
        for handle in [
            input.fileHandleForReading,
            input.fileHandleForWriting,
            output.fileHandleForReading,
            output.fileHandleForWriting,
            errors.fileHandleForReading,
            errors.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }
}

private final class ClaudeBoundedDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 64 * 1_024))
    }

    func append(_ data: Data) {
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            if remaining > 0 { storage.append(data.prefix(remaining)) }
            if data.count > remaining { exceeded = true }
        }
    }

    var data: Data { lock.withLock { storage } }
    var didExceedLimit: Bool { lock.withLock { exceeded } }
}
