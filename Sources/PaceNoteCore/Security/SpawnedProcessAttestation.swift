import Darwin
import Foundation
import Security

public enum SpawnedProcessAttestationError: Error, Equatable, Sendable {
    case untrustedProcess
}

public enum SpawnedProcessAttestation {
    public static func validateCodex(processID: pid_t, executableURL: URL) throws {
        try validate(
            processID: processID,
            executableURL: executableURL,
            teamIdentifier: CodexBinaryAuthenticityValidator.openAITeamIdentifier,
            signingIdentifier: CodexBinaryAuthenticityValidator.codexSigningIdentifier
        )
    }

    public static func validateClaude(processID: pid_t, executableURL: URL) throws {
        try validate(
            processID: processID,
            executableURL: executableURL,
            teamIdentifier: ClaudeBinaryAuthenticityValidator.anthropicTeamIdentifier,
            signingIdentifier: ClaudeBinaryAuthenticityValidator.claudeCodeSigningIdentifier
        )
    }

    private static func validate(
        processID: pid_t,
        executableURL: URL,
        teamIdentifier: String,
        signingIdentifier: String
    ) throws {
        let expected = executableURL.standardizedFileURL
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let pathLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { throw SpawnedProcessAttestationError.untrustedProcess }
        let pathEnd = pathBuffer.firstIndex(of: 0) ?? min(Int(pathLength), pathBuffer.count)
        let actualPath = String(
            decoding: pathBuffer[..<pathEnd].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard URL(fileURLWithPath: actualPath).standardizedFileURL == expected else {
            throw SpawnedProcessAttestationError.untrustedProcess
        }

        let attributes =
            [kSecGuestAttributePid as String: NSNumber(value: processID)]
            as CFDictionary
        var guestCode: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode)
                == errSecSuccess,
            let guestCode
        else {
            throw SpawnedProcessAttestationError.untrustedProcess
        }

        let requirementText =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
            + "and identifier \"\(signingIdentifier)\""
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(
                guestCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
            ) == errSecSuccess
        else {
            throw SpawnedProcessAttestationError.untrustedProcess
        }
    }
}
