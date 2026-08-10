import Darwin
import Foundation

public struct CodexProcessTransportConfiguration: Sendable {
    public let executableURL: URL
    public let requestTimeout: Duration
    public let maximumMessageBytes: Int
    public let arguments: [String]
    public let environment: [String: String]?
    public let terminationTimeout: Duration
    public let forceKillTimeout: Duration
    public let exitPollInterval: Duration
    public let postLaunchValidator: @Sendable (pid_t, URL) throws -> Void

    public init(
        executableURL: URL,
        requestTimeout: Duration = .seconds(15),
        maximumMessageBytes: Int = 8 * 1_024 * 1_024,
        arguments: [String] = ["app-server", "--stdio"],
        environment: [String: String]? = nil,
        terminationTimeout: Duration = .seconds(1),
        forceKillTimeout: Duration = .seconds(1),
        exitPollInterval: Duration = .milliseconds(10),
        postLaunchValidator: @escaping @Sendable (pid_t, URL) throws -> Void = { _, _ in }
    ) {
        precondition(terminationTimeout > .zero)
        precondition(forceKillTimeout > .zero)
        precondition(exitPollInterval > .zero)
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout
        self.maximumMessageBytes = maximumMessageBytes
        self.arguments = arguments
        self.environment = environment
        self.terminationTimeout = terminationTimeout
        self.forceKillTimeout = forceKillTimeout
        self.exitPollInterval = exitPollInterval
        self.postLaunchValidator = postLaunchValidator
    }
}

public actor CodexProcessTransport: CodexRPCTransporting {
    private enum State {
        case idle
        case running
        case stopping
        case stopped
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: CodexProcessTransportConfiguration
    private var state = State.idle
    private var processID: pid_t?
    private var processGroupID: pid_t?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var reaperTask: Task<Void, Never>?
    private var inputBuffer = Data()
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [CodexRPCID: PendingRequest] = [:]
    private var eventContinuations: [UUID: AsyncStream<CodexTransportEvent>.Continuation] = [:]

    public init(configuration: CodexProcessTransportConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard state == .idle else {
            if state == .running { return }
            throw CodexClientError.transportUnavailable
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var launchedProcessID: pid_t?
        do {
            let processID = try Self.spawn(
                configuration: configuration,
                standardInput: inputPipe.fileHandleForReading.fileDescriptor,
                standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
                standardError: errorPipe.fileHandleForWriting.fileDescriptor,
                descriptorsToClose: [
                    inputPipe.fileHandleForWriting.fileDescriptor,
                    outputPipe.fileHandleForReading.fileDescriptor,
                    errorPipe.fileHandleForReading.fileDescriptor,
                ]
            )
            launchedProcessID = processID
            try configuration.postLaunchValidator(
                processID,
                configuration.executableURL
            )
        } catch {
            Self.terminateProcessGroupAndReap(launchedProcessID: launchedProcessID)
            Self.closeAll(inputPipe, outputPipe, errorPipe)
            throw CodexClientError.transportUnavailable
        }
        guard let launchedProcessID else {
            Self.closeAll(inputPipe, outputPipe, errorPipe)
            throw CodexClientError.transportUnavailable
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        self.processID = launchedProcessID
        self.processGroupID = launchedProcessID
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        state = .running
        reaperTask = Task.detached(priority: .utility) { [weak self] in
            var waitStatus: Int32 = 0
            while Darwin.waitpid(launchedProcessID, &waitStatus, 0) == -1, errno == EINTR {}
            await self?.processExited(processID: launchedProcessID, status: waitStatus)
        }

        let outputHandle = outputPipe.fileHandleForReading
        outputTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else { break }
                await self?.receive(data)
            }
            await self?.streamEnded()
        }

        let errorHandle = errorPipe.fileHandleForReading
        errorTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let data = errorHandle.availableData
                guard !data.isEmpty else { break }
                // Drain stderr to prevent subprocess backpressure. Never retain or log it.
            }
        }
    }

    public func stop() async {
        guard state == .running else {
            if state == .idle {
                state = .stopped
            } else if state == .stopping {
                await waitForConcurrentStop()
            }
            return
        }

        state = .stopping
        try? inputPipe?.fileHandleForWriting.close()
        guard let stoppingProcessID = processID,
            let stoppingProcessGroupID = processGroupID
        else {
            finishTransport(error: CodexClientError.transportClosed)
            return
        }

        Self.signalProcessGroup(stoppingProcessGroupID, signal: SIGTERM)
        var exited = await waitForExit(
            of: stoppingProcessID,
            processGroupID: stoppingProcessGroupID,
            timeout: configuration.terminationTimeout
        )
        if !exited {
            Self.signalProcessGroup(stoppingProcessGroupID, signal: SIGKILL)
            exited = await waitForExit(
                of: stoppingProcessID,
                processGroupID: stoppingProcessGroupID,
                timeout: configuration.forceKillTimeout
            )
        }
        _ = exited
        outputTask?.cancel()
        errorTask?.cancel()
        finishTransport(error: CodexClientError.transportClosed)
    }

    public func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard state == .running else { throw CodexClientError.transportClosed }

        let id = CodexRPCID.integer(nextRequestID)
        nextRequestID += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self, timeout = configuration.requestTimeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id: id)
                }
                pendingRequests[id] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                do {
                    try write(CodexWireCodec.request(method: method, id: id, params: params))
                } catch {
                    let pending = pendingRequests.removeValue(forKey: id)
                    pending?.timeoutTask.cancel()
                    pending?.continuation.resume(throwing: CodexClientError.transportClosed)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    public func sendNotification(method: String, params: JSONValue?) async throws {
        guard state == .running else { throw CodexClientError.transportClosed }
        do {
            try write(CodexWireCodec.notification(method: method, params: params))
        } catch {
            throw CodexClientError.transportClosed
        }
    }

    public func events() async -> AsyncStream<CodexTransportEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func write(_ data: Data) throws {
        guard data.count <= configuration.maximumMessageBytes,
            let inputPipe
        else {
            throw CodexClientError.transportClosed
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard state == .running else { return }
        inputBuffer.append(data)
        guard inputBuffer.count <= configuration.maximumMessageBytes else {
            failProtocol()
            return
        }

        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            var line = Data(inputBuffer[..<newline])
            inputBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }

            do {
                try handle(CodexWireCodec.decodeLine(line))
            } catch {
                failProtocol()
                return
            }
        }
    }

    private func handle(_ message: CodexInboundMessage) throws {
        switch message {
        case .response(let id, let result, let error):
            guard let pending = pendingRequests.removeValue(forKey: id) else {
                return
            }
            pending.timeoutTask.cancel()
            if let error {
                pending.continuation.resume(
                    throwing: CodexClientError.requestFailed(
                        method: pending.method,
                        code: error.code
                    )
                )
            } else if let result {
                pending.continuation.resume(returning: result)
            } else {
                pending.continuation.resume(
                    throwing: CodexClientError.invalidResponse(method: pending.method)
                )
            }

        case .notification(let notification):
            publish(.notification(notification))

        case .serverRequest(let id, let method, let params):
            // PaceNote never delegates approval, auth refresh, or tool decisions to app-server.
            // Reject every server-initiated request and let the client fail the active turn closed.
            try write(CodexWireCodec.rejectedServerRequest(id: id))
            publish(
                .rejectedServerRequest(
                    method: CodexSafeLabel.method(method),
                    threadID: params?["threadId"]?.stringValue,
                    turnID: params?["turnId"]?.stringValue,
                    itemID: params?["itemId"]?.stringValue
                )
            )
        }
    }

    private func timeoutRequest(id: CodexRPCID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.continuation.resume(
            throwing: CodexClientError.requestTimedOut(method: pending.method)
        )
    }

    private func cancelRequest(id: CodexRPCID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func publish(_ event: CodexTransportEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func streamEnded() {
        guard state == .running else { return }
        if let processGroupID {
            Self.signalProcessGroup(processGroupID, signal: SIGKILL)
        }
        finishTransport(error: CodexClientError.transportClosed)
    }

    func activeProcessIdentifier() -> Int32? {
        processID
    }

    private func processExited(processID terminatedProcessID: pid_t, status: Int32) {
        _ = status
        guard processID == terminatedProcessID else { return }
        if let processGroupID {
            Self.signalProcessGroup(processGroupID, signal: SIGKILL)
        }
        processID = nil
        processGroupID = nil
        switch state {
        case .running:
            finishTransport(error: CodexClientError.transportClosed)
        case .stopped:
            break
        case .idle, .stopping:
            break
        }
    }

    private func failProtocol() {
        if let processGroupID {
            Self.signalProcessGroup(processGroupID, signal: SIGKILL)
        }
        finishTransport(error: CodexClientError.malformedMessage)
    }

    private func finishTransport(error: any Error) {
        guard state != .stopped else { return }
        state = .stopped
        outputTask?.cancel()
        errorTask?.cancel()

        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }

        publish(.disconnected)
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()

        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        inputBuffer.removeAll(keepingCapacity: false)
    }

    private func waitForExit(
        of targetProcessID: pid_t,
        processGroupID targetProcessGroupID: pid_t,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while (processID == targetProcessID || Self.processGroupExists(targetProcessGroupID)),
            clock.now < deadline
        {
            if Task.isCancelled {
                await Task.yield()
            } else {
                try? await Task.sleep(for: configuration.exitPollInterval)
            }
        }
        return processID != targetProcessID && !Self.processGroupExists(targetProcessGroupID)
    }

    private func waitForConcurrentStop() async {
        let clock = ContinuousClock()
        let maximumWait =
            configuration.terminationTimeout
            + configuration.forceKillTimeout
            + .milliseconds(250)
        let deadline = clock.now + maximumWait
        while state == .stopping, clock.now < deadline {
            if Task.isCancelled {
                await Task.yield()
            } else {
                try? await Task.sleep(for: configuration.exitPollInterval)
            }
        }
    }

    private static func spawn(
        configuration: CodexProcessTransportConfiguration,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        descriptorsToClose: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CodexClientError.transportUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let duplicates = [
            (standardInput, STDIN_FILENO),
            (standardOutput, STDOUT_FILENO),
            (standardError, STDERR_FILENO),
        ]
        for (source, destination) in duplicates {
            guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
                throw CodexClientError.transportUnavailable
            }
        }
        let inherited = Set(duplicates.map(\.0) + descriptorsToClose)
            .filter { ![STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains($0) }
        for descriptor in inherited {
            guard posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0 else {
                throw CodexClientError.transportUnavailable
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CodexClientError.transportUnavailable
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CodexClientError.transportUnavailable
        }

        let arguments = [configuration.executableURL.path] + configuration.arguments
        let environment = (configuration.environment ?? ProcessInfo.processInfo.environment)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let result = withMutableCStringArray(arguments) { argumentVector in
            withMutableCStringArray(environment) { environmentVector in
                configuration.executableURL.path.withCString { executablePath in
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
        guard result == 0, processID > 1 else {
            throw CodexClientError.transportUnavailable
        }
        return processID
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func terminateProcessGroupAndReap(launchedProcessID: pid_t?) {
        guard let launchedProcessID, launchedProcessID > 1 else { return }
        signalProcessGroup(launchedProcessID, signal: SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(launchedProcessID, &status, 0) == -1, errno == EINTR {}
    }

    private static func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) {
        guard processGroupID > 1 else { return }
        _ = Darwin.killpg(processGroupID, signal)
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1 else { return false }
        if Darwin.killpg(processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func closeAll(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}
