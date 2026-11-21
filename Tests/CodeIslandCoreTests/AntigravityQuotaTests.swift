import XCTest
@testable import CodeIslandCore

final class AntigravityQuotaTests: XCTestCase {
    func testParseProcessesFiltersAntigravityAndExtractsFlags() {
        let ps = """
          101 /Applications/Windsurf.app/Contents/Resources/language_server_macos_arm --csrf_token windsurf-tok
          202 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity --csrf_token agy-secret-123 --extension_server_port 54321
          303 /Users/test/.antigravity/language_server_macos_x64 --csrf_token=tok_eq_456 --extension_server_port=60000
          350 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token agy2-token-789
          404 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        """
        let processes = AntigravityQuotaLoader.parseProcesses(ps)
        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[0], .init(pid: 202, csrfToken: "agy-secret-123", extensionServerPort: 54321))
        XCTAssertEqual(processes[1], .init(pid: 303, csrfToken: "tok_eq_456", extensionServerPort: 60000))
        XCTAssertEqual(processes[2], .init(pid: 350, csrfToken: "agy2-token-789", extensionServerPort: nil))
    }

    func testParseListeningPortsAndOrdering() {
        let lsof = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_s  202 user   10u  IPv4 0x1234      0t0  TCP 127.0.0.1:54321 (LISTEN)
        language_s  202 user   11u  IPv4 0x1235      0t0  TCP 127.0.0.1:54322 (LISTEN)
        language_s  202 user   12u  IPv6 0x1236      0t0  TCP [::1]:54322 (LISTEN)
        language_s  202 user   13u  IPv4 0x1237      0t0  TCP 192.168.1.5:9999 (LISTEN)
        language_s  202 user   14u  IPv4 0x1238      0t0  TCP *:54323 (LISTEN)
        """
        let ports = AntigravityQuotaLoader.parseListeningPorts(lsof)
        XCTAssertEqual(ports, [54321, 54322, 54323])

        let ordered = AntigravityQuotaLoader.orderedCandidatePorts(listening: ports, extensionServerPort: 54321)
        XCTAssertEqual(ordered, [54322, 54323, 54321])
    }

    func testParseQuotaSummaryPrefersGeminiAndSortsShortWindowFirst() {
        let json = """
        {
          "groups": [
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "window": "5h",
                  "remainingFraction": 0.9,
                  "resetTime": "2026-10-21T15:16:05Z"
                }
              ]
            },
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "remainingFraction": 0.96,
                  "resetTime": "2026-10-28T08:29:53Z"
                },
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.85,
                  "resetTime": "2026-10-21T13:29:53Z"
                }
              ]
            }
          ]
        }
        """
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let snapshot = AntigravityQuotaLoader.parseQuotaSummary(Data(json.utf8), capturedAt: now)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.capturedAt, now)
        XCTAssertEqual(snapshot?.primaryGroup.name, "Gemini Models")
        XCTAssertEqual(snapshot?.primaryGroup.windows.count, 2)
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].label, "5h")
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].usedPercent ?? -1, 15.0, accuracy: 0.001)
        XCTAssertNotNil(snapshot?.primaryGroup.windows[0].resetsAt)
        XCTAssertEqual(snapshot?.primaryGroup.windows[1].label, "weekly")
        XCTAssertEqual(snapshot?.primaryGroup.windows[1].usedPercent ?? -1, 4.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.groups.count, 2)
    }

    func testParseUserStatusFallbackHandlesExhaustedAndPlanName() {
        let json = """
        {
          "userStatus": {
            "planStatus": {
              "planInfo": {
                "planDisplayName": "Google AI Ultra"
              }
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3 Pro (High)",
                  "modelOrAlias": { "model": "MODEL_GEMINI_PRO" },
                  "quotaInfo": {
                    "remainingFraction": 0.4,
                    "resetTime": "2026-10-21T18:00:00Z"
                  }
                },
                {
                  "label": "Gemini 3 Flash",
                  "modelOrAlias": { "model": "MODEL_GEMINI_FLASH" },
                  "quotaInfo": {
                    "resetTime": "2026-10-21T19:00:00Z"
                  }
                },
                {
                  "label": "Claude Sonnet",
                  "modelOrAlias": { "model": "MODEL_CLAUDE" },
                  "quotaInfo": {
                    "remainingFraction": 0.75,
                    "resetTime": "2026-10-21T20:00:00Z"
                  }
                }
              ]
            }
          }
        }
        """
        let snapshot = AntigravityQuotaLoader.parseUserStatus(Data(json.utf8))
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.planName, "Google AI Ultra")
        XCTAssertEqual(snapshot?.primaryGroup.name, "Gemini Models")
        XCTAssertEqual(snapshot?.primaryGroup.windows.count, 1)
        // Exhausted model (omitted remainingFraction with resetTime) reports 100% used and surfaces first
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].usedPercent ?? -1, 100.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.groups.count, 2)
    }

    func testParseCommandModelConfigsFallback() {
        let json = """
        {
          "clientModelConfigs": [
            {
              "label": "Claude Opus",
              "modelOrAlias": { "model": "MODEL_CLAUDE_OPUS" },
              "quotaInfo": {
                "remainingFraction": 0.2,
                "resetTime": "2026-10-21T20:00:00Z"
              }
            }
          ]
        }
        """
        let snapshot = AntigravityQuotaLoader.parseUserStatus(Data(json.utf8))
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.primaryGroup.name, "Claude and GPT models")
        XCTAssertEqual(snapshot?.primaryGroup.windows.first?.usedPercent ?? -1, 80.0, accuracy: 0.001)
    }

    func testParseCLIUsageOutputMatchesAgyJSON() {
        let json = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "response": "Gemini Models\\tWeekly Limit Remaining\\t95%\\t2026-11-28T16:39:32Z\\n",
          "duration_seconds": 0,
          "num_turns": 0,
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.9473769068717957,
                      "reset_time": "2026-11-28T16:39:32Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.8708192110061646,
                      "reset_time": "2026-11-21T21:39:32Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "window": "weekly",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-28T17:06:07Z"
                    },
                    {
                      "id": "3p-5h",
                      "window": "5h",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-21T22:06:07Z"
                    }
                  ]
                },
                {
                  "name": "Gemini 4 Argon",
                  "buckets": [
                    {
                      "id": "gemini-argon-wtu-weekly",
                      "window": "weekly",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-28T17:06:07Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_280_000)
        let snapshot = AntigravityQuotaLoader.parseCLIUsage(Data(json.utf8), capturedAt: now)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.primaryGroup.name, "Gemini Models")
        XCTAssertEqual(snapshot?.primaryGroup.windows.count, 2)
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].id, "gemini-5h")
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].label, "5h")
        XCTAssertEqual(snapshot?.primaryGroup.windows[0].usedPercent ?? -1, 12.918, accuracy: 0.01)
        XCTAssertEqual(snapshot?.primaryGroup.windows[1].id, "gemini-weekly")
        XCTAssertEqual(snapshot?.primaryGroup.windows[1].label, "weekly")
        XCTAssertEqual(snapshot?.primaryGroup.windows[1].usedPercent ?? -1, 5.262, accuracy: 0.01)
        XCTAssertEqual(snapshot?.groups.count, 3)
    }

    func testFindAGYExecutableChecksHomeLocalBinFirst() {
        let found = AntigravityQuotaLoader.findAGYExecutable(
            homeDirectory: "/Users/demo",
            environmentPath: "/usr/bin:/custom/bin",
            isExecutable: { $0 == "/Users/demo/.local/bin/agy" }
        )
        XCTAssertEqual(found, "/Users/demo/.local/bin/agy")
    }
}
