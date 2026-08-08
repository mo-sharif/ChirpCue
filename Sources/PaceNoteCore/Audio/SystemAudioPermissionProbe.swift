import CoreAudio
import Darwin
import Foundation

public protocol SystemAudioPermissionProviding: Sendable {
    func status() async -> AudioPermissionStatus
    func request() async throws -> AudioPermissionStatus
}

/// Requests macOS audio-capture permission by creating a private process tap without an aggregate
/// device or IO callback. No audio frames can be delivered by this probe.
public actor SystemAudioPermissionProbe: SystemAudioPermissionProviding {
    private let system = AudioHardwareSystem.shared
    private var lastKnownStatus: AudioPermissionStatus = .notDetermined

    public init() {}

    public func status() -> AudioPermissionStatus {
        lastKnownStatus
    }

    public func request() throws -> AudioPermissionStatus {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: []
        )
        description.name = "PaceNote permission check"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            guard let tap = try system.makeProcessTap(description: description) else {
                throw AudioCaptureError.sourceUnavailable
            }
            defer { try? system.destroyProcessTap(tap) }
            lastKnownStatus = .granted
            return .granted
        } catch let error as AudioHardwareError {
            if error.error == kAudioDevicePermissionsError {
                lastKnownStatus = .denied
                return .denied
            }
            throw AudioCaptureError.systemFailure(code: error.error)
        }
    }
}
