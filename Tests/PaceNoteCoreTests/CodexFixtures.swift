import Foundation

@testable import PaceNoteCore

enum CodexFixtures {
    static let initializeParams = #"""
        {
          "clientInfo": {"name":"pacenote","title":"ChirpCue","version":"0.1.0"},
          "capabilities": {"experimentalApi":true,"requestAttestation":false}
        }
        """#

    static let initializeResult = #"""
        {
          "userAgent":"Codex Desktop/0.147.0-alpha.1.2",
          "codexHome":"/Users/redacted/.codex",
          "platformFamily":"unix",
          "platformOs":"macos"
        }
        """#

    static let accountResult = #"""
        {
          "account":{"type":"chatgpt","email":"person@example.invalid","planType":"pro"},
          "requiresOpenaiAuth":true
        }
        """#

    static let modelPage = #"""
        {
          "data":[{
            "id":"quick-model",
            "model":"quick-model",
            "displayName":"Quick Model",
            "hidden":false,
            "supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"}],
            "defaultReasoningEffort":"low",
            "inputModalities":["text"],
            "supportsPersonality":false,
            "serviceTiers":[],
            "defaultServiceTier":null,
            "isDefault":true
          }],
          "nextCursor":null
        }
        """#

    static let rateLimitsResult = #"""
        {
          "rateLimits":{
            "limitId":"codex",
            "limitName":null,
            "primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1900000000},
            "secondary":null,
            "credits":null,
            "individualLimit":null,
            "spendControlReached":false,
            "planType":"pro",
            "rateLimitReachedType":null
          },
          "rateLimitsByLimitId":null,
          "rateLimitResetCredits":null
        }
        """#

    static let permissionProfilesResult = #"""
        {
          "data":[{"id":":read-only","description":null,"allowed":true}],
          "nextCursor":null
        }
        """#

    static let skillsResult = #"""
        {
          "data":[{
            "cwd":"/tmp/pacenote-snapshot",
            "skills":[{
              "name":"repo-answer",
              "description":"Answer from verified repository evidence.",
              "path":"/tmp/pacenote-snapshot/skills/repo-answer/SKILL.md",
              "scope":"repo",
              "enabled":true
            }],
            "errors":[]
          }]
        }
        """#

    static let baseThreadResult = #"""
        {
          "thread":{"id":"base-thread","sessionId":"base-thread","forkedFromId":null,"ephemeral":false},
          "model":"deep-model",
          "modelProvider":"openai",
          "serviceTier":null,
          "cwd":"/tmp/pacenote-snapshot",
          "runtimeWorkspaceRoots":["/tmp/pacenote-snapshot"],
          "instructionSources":["/tmp/pacenote-snapshot/AGENTS.md"],
          "approvalPolicy":"never",
          "activePermissionProfile":{"id":":read-only","extends":null},
          "reasoningEffort":"medium"
        }
        """#

    static let forkThreadResult = #"""
        {
          "thread":{"id":"fork-thread","sessionId":"fork-thread","forkedFromId":"base-thread","ephemeral":true},
          "model":"quick-model",
          "modelProvider":"openai",
          "serviceTier":null,
          "cwd":"/tmp/pacenote-snapshot",
          "runtimeWorkspaceRoots":["/tmp/pacenote-snapshot"],
          "instructionSources":["/tmp/pacenote-snapshot/AGENTS.md"],
          "approvalPolicy":"never",
          "activePermissionProfile":{"id":":read-only","extends":null},
          "reasoningEffort":"low"
        }
        """#

    static let turnStartResult = #"""
        {"turn":{"id":"turn-1","status":"inProgress","items":[],"error":null}}
        """#

    static let agentDeltaNotification = #"""
        {
          "method":"item/agentMessage/delta",
          "params":{"threadId":"fork-thread","turnId":"turn-1","itemId":"item-1","delta":"A short answer"}
        }
        """#

    static let itemCompletedNotification = #"""
        {
          "method":"item/completed",
          "params":{
            "threadId":"fork-thread",
            "turnId":"turn-1",
            "completedAtMs":1900000000000,
            "item":{"type":"agentMessage","id":"item-1","text":"A short answer","phase":"final_answer","memoryCitation":null}
          }
        }
        """#

    static let turnCompletedNotification = #"""
        {
          "method":"turn/completed",
          "params":{
            "threadId":"fork-thread",
            "turn":{"id":"turn-1","status":"completed","items":[],"error":null}
          }
        }
        """#

    static let serverRequest = #"""
        {
          "method":"item/commandExecution/requestApproval",
          "id":77,
          "params":{"threadId":"fork-thread","turnId":"turn-1","itemId":"command-item","reason":"/Users/private/repository"}
        }
        """#

    static let serverError = #"""
        {
          "id":9,
          "error":{"code":-32600,"message":"failure at /Users/private/repository with token-secret"}
        }
        """#

    static let realtimeSchema = #"""
        {
          "definitions": {
            "ClientRequest": {"oneOf":[
              {"properties":{"method":{"enum":["thread/realtime/start"]}}},
              {"properties":{"method":{"enum":["thread/realtime/appendText"]}}},
              {"properties":{"method":{"enum":["thread/realtime/stop"]}}}
            ]},
            "ServerNotification": {"oneOf":[
              {"properties":{"method":{"enum":["thread/realtime/started"]}}},
              {"properties":{"method":{"enum":["thread/realtime/itemAdded"]}}},
              {"properties":{"method":{"enum":["thread/realtime/transcript/delta"]}}},
              {"properties":{"method":{"enum":["thread/realtime/transcript/done"]}}},
              {"properties":{"method":{"enum":["thread/realtime/error"]}}},
              {"properties":{"method":{"enum":["thread/realtime/closed"]}}}
            ]},
            "ThreadRealtimeStartParams": {"properties":{
              "threadId":{},
              "clientManagedHandoffs":{},
              "outputModality":{},
              "prompt":{},
              "version":{}
            }},
            "RealtimeConversationVersion":{"enum":["v1","v2","v3"]},
            "RealtimeOutputModality":{"enum":["text","audio"]}
          }
        }
        """#

    static let realtimeStartedNotification = #"""
        {"method":"thread/realtime/started","params":{"threadId":"fork-thread","realtimeSessionId":"rt-1","version":"v3"}}
        """#

    static let realtimeDeltaNotification = #"""
        {"method":"thread/realtime/transcript/delta","params":{"threadId":"fork-thread","role":"assistant","delta":"Say this"}}
        """#

    static let realtimeDoneNotification = #"""
        {"method":"thread/realtime/transcript/done","params":{"threadId":"fork-thread","role":"assistant","text":"Say this now."}}
        """#

    static let realtimeItemNotification = #"""
        {"method":"thread/realtime/itemAdded","params":{"threadId":"fork-thread","item":{"type":"message","role":"assistant"}}}
        """#

    static let realtimeClosedNotification = #"""
        {"method":"thread/realtime/closed","params":{"threadId":"fork-thread","reason":null}}
        """#

    static let emptyResult = #"{}"#

    static func value(_ fixture: String) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(fixture.utf8))
        } catch {
            preconditionFailure("Invalid JSON fixture: \(error)")
        }
    }

    static func inbound(_ fixture: String) -> CodexServerNotification {
        do {
            switch try CodexWireCodec.decodeLine(Data(fixture.utf8)) {
            case .notification(let notification): return notification
            default: preconditionFailure("Fixture is not a notification.")
            }
        } catch {
            preconditionFailure("Invalid Codex wire fixture: \(error)")
        }
    }
}
