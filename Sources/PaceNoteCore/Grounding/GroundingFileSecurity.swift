import Darwin
import Foundation

struct GroundingFileSecurity: Sendable {
    enum ReadError: Error {
        case missing
        case changed
        case unsafe(UnsafeFileKind)
        case exceedsByteLimit
        case io
    }

    struct SecureBytes: Sendable {
        let data: Data
        let hash: String
        let byteCount: UInt64
    }

    func canonicalRepositoryRoot(_ root: URL) throws -> URL {
        let standardized = root.standardizedFileURL
        var beforeResolution = stat()
        guard lstat(standardized.path, &beforeResolution) == 0,
            fileKind(beforeResolution.st_mode) == .directory
        else {
            throw GroundingError.invalidRepositoryRoot
        }

        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let didResolve = standardized.path.withCString { path in
            Darwin.realpath(path, &resolvedBuffer) != nil
        }
        guard didResolve else { throw GroundingError.invalidRepositoryRoot }
        let pathEnd = resolvedBuffer.firstIndex(of: 0) ?? resolvedBuffer.endIndex
        let resolvedPath = String(
            decoding: resolvedBuffer[..<pathEnd].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let resolved = URL(
            fileURLWithPath: resolvedPath,
            isDirectory: true
        )

        var afterResolution = stat()
        var resolvedMetadata = stat()
        guard lstat(standardized.path, &afterResolution) == 0,
            lstat(resolved.path, &resolvedMetadata) == 0,
            fileKind(afterResolution.st_mode) == .directory,
            fileKind(resolvedMetadata.st_mode) == .directory,
            beforeResolution.st_dev == afterResolution.st_dev,
            beforeResolution.st_ino == afterResolution.st_ino,
            beforeResolution.st_dev == resolvedMetadata.st_dev,
            beforeResolution.st_ino == resolvedMetadata.st_ino
        else {
            throw GroundingError.invalidRepositoryRoot
        }
        return resolved
    }

    func validate(relativePath: String) throws {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\0")
        else {
            throw GroundingError.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw GroundingError.invalidRelativePath(relativePath)
        }
    }

    func secureRead(
        root: URL,
        relativePath: String,
        maximumByteCount: UInt64 = GroundingResourceLimits().maximumFileBytes,
        budget: GroundingResourceBudget? = nil
    ) throws -> SecureBytes {
        try budget?.checkDeadline()
        try validate(relativePath: relativePath)
        let descriptor = try openRegularFile(root: root, relativePath: relativePath)
        defer { close(descriptor) }

        var initialMetadata = stat()
        guard fstat(descriptor, &initialMetadata) == 0,
            initialMetadata.st_size >= 0
        else {
            throw ReadError.changed
        }
        let maximumRepresentableByteCount = min(maximumByteCount, UInt64(Int.max))
        guard UInt64(initialMetadata.st_size) <= maximumRepresentableByteCount else {
            throw ReadError.exceedsByteLimit
        }

        var bytes = Data()
        if initialMetadata.st_size > 0 {
            bytes.reserveCapacity(min(Int(initialMetadata.st_size), 64 * 1_024))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try budget?.checkDeadline()
            let remaining = maximumByteCount - UInt64(bytes.count)
            let nextReadSize = Int(min(UInt64(buffer.count), remaining + (remaining < UInt64.max ? 1 : 0)))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, nextReadSize)
            }
            if count > 0 {
                guard UInt64(count) <= remaining else {
                    throw ReadError.exceedsByteLimit
                }
                try budget?.chargeScannedBytes(UInt64(count))
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw ReadError.io
            }
        }

        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
            fileKind(finalMetadata.st_mode) == nil,
            finalMetadata.st_nlink == 1,
            finalMetadata.st_size >= 0,
            UInt64(finalMetadata.st_size) == UInt64(bytes.count)
        else {
            throw ReadError.changed
        }

        return SecureBytes(
            data: bytes,
            hash: GroundingDigest.sha256(bytes),
            byteCount: UInt64(bytes.count)
        )
    }

    func validateRegularFile(root: URL, relativePath: String) throws {
        try validate(relativePath: relativePath)
        let descriptor = try openRegularFile(root: root, relativePath: relativePath)
        close(descriptor)
    }

    func createPrivateDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw GroundingError.cannotCreatePrivateSnapshot
            }
        } catch let error as GroundingError {
            throw error
        } catch {
            throw GroundingError.cannotCreatePrivateSnapshot
        }
    }

    func writePrivate(_ data: Data, root: URL, relativePath: String) throws {
        try validate(relativePath: relativePath)
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { throw ReadError.io }
        let rootDescriptor = root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { throw ReadError.io }
        defer { close(rootDescriptor) }
        try validatePrivateDirectoryDescriptor(rootDescriptor)

        var parentDescriptor = rootDescriptor
        defer {
            if parentDescriptor != rootDescriptor { close(parentDescriptor) }
        }
        for component in components.dropLast() {
            if mkdirat(parentDescriptor, component, 0o700) != 0, errno != EEXIST {
                throw ReadError.io
            }
            let childDescriptor = openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard childDescriptor >= 0 else { throw ReadError.io }
            do {
                try validatePrivateDirectoryDescriptor(childDescriptor)
                guard fchmod(childDescriptor, 0o700) == 0 else { throw ReadError.io }
            } catch {
                close(childDescriptor)
                throw error
            }
            if parentDescriptor != rootDescriptor { close(parentDescriptor) }
            parentDescriptor = childDescriptor
        }

        let descriptor = openat(
            parentDescriptor,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw ReadError.io }
        defer { close(descriptor) }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count > 0 {
                    remaining -= count
                    cursor = cursor.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw ReadError.io
                }
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o600) == 0 else {
            throw ReadError.io
        }
    }

    private func validatePrivateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            fileKind(metadata.st_mode) == .directory,
            metadata.st_uid == getuid()
        else {
            throw ReadError.io
        }
    }

    func enumerateRegularFiles(
        root: URL,
        maximumFileCount: Int = GroundingResourceLimits().maximumFileCount,
        budget: GroundingResourceBudget? = nil
    ) throws -> [String] {
        try budget?.checkDeadline()
        let canonicalRoot = try canonicalRepositoryRoot(root)
        var result: [String] = []
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else {
            throw ReadError.io
        }

        while let child = enumerator.nextObject() as? URL {
            try budget?.chargeTraversalEntry()
            let relativePath = try relativePath(for: child, root: canonicalRoot)
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0 else { throw ReadError.changed }
            if fileKind(metadata.st_mode) == .directory {
                continue
            }
            if let kind = fileKind(metadata.st_mode) {
                throw GroundingError.unsafeFile(relativePath: relativePath, kind: kind)
            }
            guard metadata.st_nlink == 1 else {
                throw GroundingError.unsafeFile(relativePath: relativePath, kind: .hardLink)
            }
            guard result.count < maximumFileCount else {
                throw GroundingError.resourceLimitExceeded(.fileCount)
            }
            result.append(relativePath)
        }
        guard !enumerationFailed else { throw ReadError.io }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    func entryKind(at url: URL) throws -> UnsafeFileKind? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { throw ReadError.changed }
            throw ReadError.io
        }
        if let kind = fileKind(metadata.st_mode) { return kind }
        return metadata.st_nlink == 1 ? nil : .hardLink
    }

    private func relativePath(for child: URL, root: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard child.path.hasPrefix(rootPath) else {
            throw GroundingError.invalidRelativePath(child.lastPathComponent)
        }
        let relativePath = String(child.path.dropFirst(rootPath.count))
        try validate(relativePath: relativePath)
        return relativePath
    }

    private func openRegularFile(root: URL, relativePath: String) throws -> Int32 {
        let components = relativePath.split(separator: "/").map(String.init)
        var directoryDescriptor = root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { throw ReadError.io }

        for component in components.dropLast() {
            var metadata = stat()
            let status = component.withCString {
                fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                close(directoryDescriptor)
                if errno == ENOENT { throw ReadError.missing }
                throw ReadError.io
            }
            guard fileKind(metadata.st_mode) == .directory else {
                close(directoryDescriptor)
                throw ReadError.unsafe(fileKind(metadata.st_mode) ?? .nonRegular)
            }

            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else {
                close(directoryDescriptor)
                throw ReadError.changed
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        guard let filename = components.last else {
            close(directoryDescriptor)
            throw ReadError.io
        }

        var beforeOpen = stat()
        let status = filename.withCString {
            fstatat(directoryDescriptor, $0, &beforeOpen, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            close(directoryDescriptor)
            if errno == ENOENT { throw ReadError.missing }
            throw ReadError.io
        }
        if let unsafeKind = fileKind(beforeOpen.st_mode) {
            close(directoryDescriptor)
            throw ReadError.unsafe(unsafeKind)
        }
        guard beforeOpen.st_nlink == 1 else {
            close(directoryDescriptor)
            throw ReadError.unsafe(.hardLink)
        }

        let descriptor = filename.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        close(directoryDescriptor)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { throw ReadError.changed }
            throw ReadError.io
        }

        var afterOpen = stat()
        guard fstat(descriptor, &afterOpen) == 0,
            fileKind(afterOpen.st_mode) == nil,
            afterOpen.st_nlink == 1,
            afterOpen.st_dev == beforeOpen.st_dev,
            afterOpen.st_ino == beforeOpen.st_ino
        else {
            close(descriptor)
            throw ReadError.changed
        }
        return descriptor
    }

    private func fileKind(_ mode: mode_t) -> UnsafeFileKind? {
        switch mode & S_IFMT {
        case S_IFREG: nil
        case S_IFLNK: .symbolicLink
        case S_IFDIR: .directory
        case S_IFSOCK: .socket
        case S_IFCHR, S_IFBLK: .device
        case S_IFIFO: .fifo
        default: .nonRegular
        }
    }
}

struct HardPathClassifier: Sendable {
    func reason(for relativePath: String) -> HardExclusionReason? {
        let components = relativePath.split(separator: "/").map { $0.lowercased() }
        guard let filename = components.last else { return .repositoryMetadata }
        let fileURL = URL(fileURLWithPath: filename)
        let extensionName = fileURL.pathExtension.lowercased()
        let stem = fileURL.deletingPathExtension().lastPathComponent.lowercased()

        if components.contains(".git") { return .repositoryMetadata }
        if components.contains(where: { ["node_modules", ".swiftpm", "pods", "vendor"].contains($0) }) {
            return .dependencyCache
        }
        if components.contains(where: { [".build", "build", "deriveddata", "dist", "coverage"].contains($0) }) {
            return .buildOutput
        }
        if components.contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) {
            return .environmentFile
        }
        if ["pem", "key", "p8", "p12", "pfx", "jks", "keystore"].contains(extensionName)
            || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(filename)
        {
            return .privateKey
        }
        if components.contains(where: { [".ssh", ".aws", ".kube", ".azure", ".gnupg"].contains($0) })
            || components.contains(".codex")
            || containsCredentialStoreDirectory(components)
            || [
                ".netrc", ".npmrc", ".pypirc", ".htpasswd", "login.keychain-db",
                "auth.json", ".credentials.json", "credentials.json", "oauth.json", "oauth2.json",
                "client_secret.json", "client-secrets.json", "application_default_credentials.json",
            ].contains(filename)
            || filename.hasPrefix("client_secret_")
            || filename.hasPrefix("service-account-")
            || filename.hasPrefix("service_account_")
            || ([
                "credentials", "credential", "keychain", "secret", "secrets", ".secrets",
                "service-account", "service_account",
            ].contains(stem)
                && ["", "json", "plist", "yaml", "yml", "toml", "db", "sqlite"].contains(extensionName))
        {
            return .credentialStore
        }
        if (["token", "tokens", ".token", ".tokens"].contains(stem)
            && ["", "json", "plist", "txt", "db"].contains(extensionName))
        {
            return .tokenFile
        }
        if ["dump", "dmp", "core", "hprof"].contains(extensionName)
            || (["dump", "backup", "database-dump"].contains(stem)
                && ["", "sql", "sqlite", "db", "json", "tar", "gz", "zip"].contains(extensionName))
        {
            return .dump
        }
        return nil
    }

    private func containsCredentialStoreDirectory(_ components: [String]) -> Bool {
        components.contains(".docker")
            || components.indices.contains { index in
                guard components[index] == ".config", components.indices.contains(index + 1) else {
                    return false
                }
                return ["gh", "gcloud", "configstore"].contains(components[index + 1])
            }
    }
}

struct GroundingSecretScanner: Sendable {
    struct Findings: Equatable, Sendable {
        let hardRuleIDs: [String]
        let softRuleIDs: [String]
    }

    private let hardPatterns: [(id: String, expression: String)] = [
        ("private-key-block", #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#),
        ("aws-access-key", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        ("github-token", #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        ("github-fine-grained-token", #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
        ("slack-token", #"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"#),
        ("stripe-secret-key", #"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        ("openai-secret-key", #"\bsk-(?:(?:proj|svcacct)-)?[A-Za-z0-9_-]{20,}\b"#),
        ("google-api-key", #"\bAIza[A-Za-z0-9_-]{20,}\b"#),
        ("bearer-token", #"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}={0,2}"#),
        ("slack-webhook", #"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]{20,}"#),
        ("discord-webhook", #"https://(?:discord(?:app)?\.com)/api/webhooks/[0-9]{6,}/[A-Za-z0-9._-]{20,}"#),
        ("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
        (
            "uri-userinfo-credential",
            #"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqp|amqps|kafka|nats|http|https)://[^\s/:@]+:[^\s/@]+@"#
        ),
    ]
    private let softPatterns: [(id: String, expression: String)] = [
        (
            "credential-assignment",
            #"(?i)\b(?:api[_-]?key|client[_-]?secret|password|access[_-]?token|auth[_-]?token|database[_-]?url|redis[_-]?url|broker[_-]?url|dsn|connection[_-]?string)\b\s*[:=]\s*[\"']?[^\s\"']{8,}"#
        )
    ]

    func findings(in data: Data) -> Findings {
        guard !data.isEmpty else { return Findings(hardRuleIDs: [], softRuleIDs: []) }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Findings(
            hardRuleIDs: matches(in: text, range: range, rules: hardPatterns),
            softRuleIDs: matches(in: text, range: range, rules: softPatterns)
        )
    }

    private func matches(
        in text: String,
        range: NSRange,
        rules: [(id: String, expression: String)]
    ) -> [String] {
        rules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.expression) else { return nil }
            return regex.firstMatch(in: text, range: range) == nil ? nil : rule.id
        }.sorted()
    }
}
