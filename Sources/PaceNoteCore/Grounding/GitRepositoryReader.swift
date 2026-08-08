import Darwin
import Foundation

struct GitRepositoryReader: Sendable {
    struct RepositoryMetadata: Equatable, Sendable {
        let branch: String
        let head: String
        let worktreeFingerprint: String
    }

    struct CommandResult: Sendable {
        let status: Int32
        let stdout: Data
    }

    private let limits: GroundingResourceLimits
    private let executableURL: URL

    init(
        limits: GroundingResourceLimits = .init(),
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) {
        self.limits = limits
        self.executableURL = executableURL
    }

    func repositoryRoot(
        startingAt root: URL,
        budget: GroundingResourceBudget? = nil
    ) throws -> URL {
        let result = try run(
            root: root,
            arguments: ["rev-parse", "--show-toplevel"],
            budget: budget
        )
        guard result.status == 0,
            let path = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            throw GroundingError.notGitRepository
        }
        try budget?.checkDeadline()
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func candidatePaths(
        root: URL,
        budget: GroundingResourceBudget? = nil
    ) throws -> [String] {
        let result = try run(
            root: root,
            arguments: ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            budget: budget
        )
        guard result.status == 0 else { throw GroundingError.gitCommandFailed("file enumeration") }

        var paths = Set<String>()
        for field in result.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            try budget?.checkDeadline()
            guard let path = String(data: Data(field), encoding: .utf8) else {
                throw GroundingError.invalidRelativePath("<non-UTF8>")
            }
            if paths.insert(path).inserted, paths.count > limits.maximumFileCount {
                throw GroundingError.resourceLimitExceeded(.fileCount)
            }
        }
        try budget?.checkDeadline()
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    func ignoredPaths(
        root: URL,
        budget: GroundingResourceBudget? = nil
    ) throws -> Set<String> {
        let result = try run(
            root: root,
            arguments: [
                "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory",
            ],
            budget: budget
        )
        guard result.status == 0 else { throw GroundingError.gitCommandFailed("ignore enumeration") }

        var paths = Set<String>()
        for field in result.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            try budget?.checkDeadline()
            guard var path = String(data: Data(field), encoding: .utf8) else {
                throw GroundingError.invalidRelativePath("<non-UTF8>")
            }
            while path.hasSuffix("/") { path.removeLast() }
            if !path.isEmpty { paths.insert(path) }
        }
        try budget?.checkDeadline()
        return paths
    }

    func metadata(
        root: URL,
        budget: GroundingResourceBudget? = nil
    ) throws -> RepositoryMetadata {
        let branchResult = try run(
            root: root,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            budget: budget
        )
        let branch =
            branchResult.status == 0
            ? trimmed(branchResult.stdout)
            : "DETACHED"

        let headResult = try run(
            root: root,
            arguments: ["rev-parse", "--verify", "HEAD"],
            budget: budget
        )
        let head = headResult.status == 0 ? trimmed(headResult.stdout) : "UNBORN"

        let statusResult = try run(
            root: root,
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=no"],
            budget: budget
        )
        guard statusResult.status == 0 else {
            throw GroundingError.gitCommandFailed("worktree state")
        }
        try budget?.checkDeadline()
        return RepositoryMetadata(
            branch: branch,
            head: head,
            worktreeFingerprint: GroundingDigest.sha256(statusResult.stdout)
        )
    }

    private func run(
        root: URL,
        arguments: [String],
        budget: GroundingResourceBudget?
    ) throws -> CommandResult {
        try budget?.checkDeadline()
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments =
            [
                "-c", "core.fsmonitor=false",
                "-c", "core.untrackedCache=false",
                "-C", root.path,
            ] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = scrubbedEnvironment()

        do {
            try process.run()
            try? output.fileHandleForWriting.close()
        } catch {
            throw GroundingError.gitCommandFailed(arguments.first ?? "operation")
        }

        let collector = BoundedGitOutputCollector(maximumByteCount: limits.maximumGitOutputBytes)
        let readHandle = output.fileHandleForReading
        let readDescriptor = readHandle.fileDescriptor
        let descriptorFlags = fcntl(readDescriptor, F_GETFL)
        guard descriptorFlags >= 0,
            fcntl(readDescriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0
        else {
            terminate(process)
            process.waitUntilExit()
            try? readHandle.close()
            throw GroundingError.gitCommandFailed(arguments.first ?? "operation")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        var exceededLimit: GroundingResourceLimit?
        while process.isRunning {
            drainOutput(descriptor: readDescriptor, into: collector)
            if collector.didExceedLimit {
                exceededLimit = .gitOutputBytes
                break
            }
            if ProcessInfo.processInfo.systemUptime - startedAt >= limits.gitCommandTimeout {
                exceededLimit = .gitCommandTimeout
                break
            }
            do {
                try budget?.checkDeadline()
            } catch {
                exceededLimit = .groundingDeadline
                break
            }
            usleep(5_000)
        }

        if exceededLimit != nil {
            terminate(process)
        }
        process.waitUntilExit()
        drainOutput(descriptor: readDescriptor, into: collector)
        try? readHandle.close()

        if collector.didExceedLimit {
            exceededLimit = .gitOutputBytes
        }
        if let exceededLimit {
            throw GroundingError.resourceLimitExceeded(exceededLimit)
        }
        try budget?.checkDeadline()
        guard !collector.didFailRead else {
            throw GroundingError.gitCommandFailed(arguments.first ?? "operation")
        }
        return CommandResult(status: process.terminationStatus, stdout: collector.data)
    }

    private func drainOutput(descriptor: Int32, into collector: BoundedGitOutputCollector) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                collector.append(Data(buffer.prefix(count)))
                if collector.didExceedLimit {
                    return
                }
            } else if count == 0 {
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                collector.markReadFailure()
                return
            }
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < graceDeadline {
            usleep(5_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func scrubbedEnvironment() -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let temporaryDirectory = ProcessInfo.processInfo.environment["TMPDIR"] {
            environment["TMPDIR"] = temporaryDirectory
        }
        if let userHome = ProcessInfo.processInfo.environment["HOME"] {
            environment["HOME"] = userHome
        }
        if let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            environment["XDG_CONFIG_HOME"] = configHome
        }
        return environment
    }

    private func trimmed(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class BoundedGitOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var storage = Data()
    private var exceededLimit = false
    private var failedRead = false

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, maximumByteCount - storage.count)
        if chunk.count > remaining {
            storage.append(chunk.prefix(remaining))
            exceededLimit = true
        } else {
            storage.append(chunk)
        }
    }

    func markReadFailure() {
        lock.lock()
        failedRead = true
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }

    var didFailRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedRead
    }
}
