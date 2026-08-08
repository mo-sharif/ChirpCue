import CoreAudio
import Darwin
import Foundation

public protocol SystemAudioPermissionProviding: Sendable {
    func status() async -> AudioPermissionStatus
    func request() async throws -> AudioPermissionStatus
}

struct SystemAudioPermissionProbeOperations: @unchecked Sendable {
    let createTap: @Sendable () throws -> AudioObjectID?
    let destroyTap: @Sendable (AudioObjectID) throws -> Void

    static let live = Self(
        createTap: {
            let description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: []
            )
            description.name = "PaceNote permission check"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            return try AudioHardwareSystem.shared.makeProcessTap(description: description)?.id
        },
        destroyTap: { tapID in
            let status = AudioHardwareDestroyProcessTap(tapID)
            guard status == noErr else {
                throw AudioCaptureError.systemFailure(code: status)
            }
        }
    )
}

/// Requests macOS audio-capture permission by creating a private process tap without an aggregate
/// device or IO callback. No audio frames can be delivered by this probe.
public actor SystemAudioPermissionProbe: SystemAudioPermissionProviding {
    private let operations: SystemAudioPermissionProbeOperations
    private var lastKnownStatus: AudioPermissionStatus = .notDetermined
    private var pendingTapID: AudioObjectID?

    public init() {
        operations = .live
    }

    init(operations: SystemAudioPermissionProbeOperations) {
        self.operations = operations
    }

    public func status() -> AudioPermissionStatus {
        lastKnownStatus
    }

    public func request() throws -> AudioPermissionStatus {
        if pendingTapID != nil {
            try destroyPendingTap()
            lastKnownStatus = .granted
            return .granted
        }

        do {
            guard let tapID = try operations.createTap() else {
                throw AudioCaptureError.sourceUnavailable
            }
            pendingTapID = tapID
        } catch let error as AudioHardwareError {
            if error.error == kAudioDevicePermissionsError {
                lastKnownStatus = .denied
                return .denied
            }
            throw AudioCaptureError.systemFailure(code: error.error)
        }

        try destroyPendingTap()
        lastKnownStatus = .granted
        return .granted
    }

    private func destroyPendingTap() throws {
        guard let pendingTapID else { return }
        try operations.destroyTap(pendingTapID)
        self.pendingTapID = nil
    }
}
