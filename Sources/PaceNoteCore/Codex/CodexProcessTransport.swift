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

    public init(
        executableURL: URL,
        requestTimeout: Duration = .seconds(15),
        maximumMessageBytes: Int = 8 * 1_024 * 1_024,
        arguments: [String] = ["app-server", "--stdio"],
        environment: [String: String]? = nil,
        terminationTimeout: Duration = .seconds(1),
        forceKillTimeout: Duration = .seconds(1),
        exitPollInterval: Duration = .milliseconds(10)
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
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
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

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processExited(
                    terminatedProcess: terminatedProcess,
                    status: status
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexClientError.transportUnavailable
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        state = .running

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
        guard let stoppingProcess = process else {
            finishTransport(error: CodexClientError.transportClosed)
            return
        }

        if stoppingProcess.isRunning {
            stoppingProcess.terminate()
        }
        var exited = await waitForExit(
            of: stoppingProcess,
            timeout: configuration.terminationTimeout
        )
        if !exited {
            forceKill(stoppingProcess)
            exited = await waitForExit(
                of: stoppingProcess,
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
        finishTransport(error: CodexClientError.transportClosed)
    }

    func activeProcessIdentifier() -> Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func processExited(terminatedProcess: Process, status: Int32) {
        _ = status
        guard process === terminatedProcess else { return }
        switch state {
        case .running:
            finishTransport(error: CodexClientError.transportClosed)
        case .stopped:
            process = nil
        case .idle, .stopping:
            break
        }
    }

    private func failProtocol() {
        if process?.isRunning == true { process?.terminate() }
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

        if process?.isRunning != true {
            process = nil
        }
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        inputBuffer.removeAll(keepingCapacity: false)
    }

    private func waitForExit(of process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning, clock.now < deadline {
            if Task.isCancelled {
                await Task.yield()
            } else {
                try? await Task.sleep(for: configuration.exitPollInterval)
            }
        }
        return !process.isRunning
    }

    private func forceKill(_ target: Process) {
        guard process === target, target.isRunning else { return }
        let pid = target.processIdentifier
        guard pid > 1, target.isRunning else { return }
        _ = Darwin.kill(pid, SIGKILL)
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
}
