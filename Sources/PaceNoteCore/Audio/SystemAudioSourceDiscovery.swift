import AppKit
import CoreAudio
import Darwin
import Foundation

public struct SystemAudioSource: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let processID: Int32
    public let bundleID: String?
    public let name: String
    public let isLikelyMeetingSource: Bool

    public init(
        processID: Int32,
        bundleID: String?,
        name: String,
        isLikelyMeetingSource: Bool
    ) {
        self.id = "pid:\(processID)"
        self.processID = processID
        self.bundleID = bundleID
        self.name = name
        self.isLikelyMeetingSource = isLikelyMeetingSource
    }

    public var captureTarget: AudioProcessTarget {
        AudioProcessTarget(processID: processID, bundleID: bundleID)
    }
}

public protocol SystemAudioSourceDiscovering: Sendable {
    func sources() async throws -> [SystemAudioSource]
}

public actor SystemAudioSourceDiscovery: SystemAudioSourceDiscovering {
    private let system = AudioHardwareSystem.shared

    public init() {}

    public func sources() throws -> [SystemAudioSource] {
        let ownProcessID = getpid()
        return Self.resilientlyResolve(try system.processes) { process in
            let processID = try process.pid
            guard processID > 0, processID != ownProcessID else { return nil }

            let bundleID = try process.bundleID
            let application = NSRunningApplication(processIdentifier: processID)
            let name = Self.displayName(
                localizedName: application?.localizedName,
                bundleID: bundleID,
                processID: processID
            )
            return SystemAudioSource(
                processID: processID,
                bundleID: bundleID,
                name: name,
                isLikelyMeetingSource: Self.isLikelyMeetingSource(
                    name: name,
                    bundleID: bundleID
                )
            )
        }
    }

    static func resilientlyResolve<Element>(
        _ elements: [Element],
        resolve: (Element) throws -> SystemAudioSource?
    ) -> [SystemAudioSource] {
        var resolved: [SystemAudioSource] = []
        resolved.reserveCapacity(elements.count)
        for element in elements {
            do {
                if let source = try resolve(element) { resolved.append(source) }
            } catch {
                // CoreAudio's process list can change between enumeration and
                // property reads. One exited or inaccessible process must not
                // hide every other selectable meeting source.
                continue
            }
        }
        return deduplicatedAndSorted(resolved)
    }

    static func deduplicatedAndSorted(_ sources: [SystemAudioSource]) -> [SystemAudioSource] {
        var byProcessID: [Int32: SystemAudioSource] = [:]
        for source in sources where byProcessID[source.processID] == nil {
            byProcessID[source.processID] = source
        }
        return byProcessID.values.sorted {
            if $0.isLikelyMeetingSource != $1.isLikelyMeetingSource {
                return $0.isLikelyMeetingSource && !$1.isLikelyMeetingSource
            }
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.processID < $1.processID
        }
    }

    static func isLikelyMeetingSource(name: String, bundleID: String?) -> Bool {
        let haystack = [name, bundleID ?? ""].joined(separator: " ").lowercased()
        let indicators = [
            "chrome", "safari", "firefox", "arc", "zoom", "teams", "facetime",
            "webex", "slack", "discord", "around", "meet",
        ]
        return indicators.contains { haystack.contains($0) }
    }

    private static func displayName(
        localizedName: String?,
        bundleID: String?,
        processID: Int32
    ) -> String {
        if let localizedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !localizedName.isEmpty
        {
            return localizedName
        }
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return "Audio process \(processID)"
    }
}
