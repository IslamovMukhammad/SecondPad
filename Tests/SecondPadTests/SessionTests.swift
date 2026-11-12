import Foundation
import Testing
@testable import SecondPad

@Suite("Live sessions from hook events")
struct SessionTests {

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(_ id: String = "s1", cwd: String = "/Users/demo/code/alpha-app", extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = ["session_id": id, "cwd": cwd, "transcript_path": "/tmp/\(id).jsonl"]
        base.merge(extra) { $1 }
        return base
    }

    @Test func eventsDriveTheState() {
        let status = ClaudeStatus()
        status.handle(event: "SessionStart", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .idle)
        #expect(status.sessionInfos.first?.project == "alpha-app")

        status.handle(event: "UserPromptSubmit", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .working)
        #expect(status.sessionInfos.first?.activity == "thinking")

        status.handle(event: "PreToolUse", payload: payload(extra: ["tool_name": "Edit", "tool_input": ["file_path": "/a/b/PanelView.swift"]]), now: t0)
        #expect(status.sessionInfos.first?.activity == "editing PanelView.swift")

        status.handle(event: "PreToolUse", payload: payload(extra: ["tool_name": "Agent"]), now: t0)
        #expect(status.sessionInfos.first?.activity == "1 task running")
        status.handle(event: "SubagentStop", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.activity == "subtask done · continuing")

        status.handle(event: "Notification", payload: payload(extra: ["notification_type": "permission_prompt",
                                                               "message": "Claude needs your permission to use Bash"]), now: t0)
        #expect(status.sessionInfos.first?.state == .waiting)
        #expect(status.sessionInfos.first?.activity == "Claude needs your permission to use Bash")

        status.handle(event: "Stop", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .done)

        status.handle(event: "SessionEnd", payload: payload(), now: t0)
        #expect(status.sessionInfos.isEmpty)
    }

    @Test func idlePromptIsNotNeedsYou() {
        let status = ClaudeStatus()
        status.handle(event: "Stop", payload: payload(), now: t0)
        status.handle(event: "Notification", payload: payload(extra: ["notification_type": "idle_prompt",
                                                               "message": "Claude is waiting for your input"]), now: t0)
        #expect(status.sessionInfos.first?.state == .done)
        status.handle(event: "Notification", payload: payload(extra: ["message": "Claude is waiting for your input"]), now: t0)
        #expect(status.sessionInfos.first?.state == .done)
    }

    @Test func failuresAndCommandsInPlainWords() {
        let status = ClaudeStatus()
        status.handle(event: "StopFailure", payload: payload(extra: ["error": "rate_limit"]), now: t0)
        #expect(status.sessionInfos.first?.state == .error)
        #expect(status.sessionInfos.first?.activity == "limit reached")
        #expect(ToolText.describe(tool: "Bash", input: ["command": "cd /x && git status"]) == "using git")
        #expect(ToolText.describe(tool: "Bash", input: ["description": "Build /Users/demo/a/App.xcodeproj"]) == "Build App.xcodeproj")
        #expect(ToolText.describe(tool: "WebFetch", input: ["url": "https://example.com/a?b"]) == "fetching example.com")
        #expect(ToolText.describe(tool: "mcp__Some_Browser__click", input: nil) == "using the browser")
        #expect(ToolText.prettyModel("claude-opus-5-5") == "Opus 5.5")
        #expect(ToolText.prettyModel("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test func settlesStaleSessions() {
        let status = ClaudeStatus()
        status.handle(event: "Stop", payload: payload("a"), now: t0)
        status.handle(event: "UserPromptSubmit", payload: payload("b", cwd: "/x/beta"), now: t0)
        // Done → idle after 90 s; transcripts "exist".
        #expect(status.refresh(now: t0.addingTimeInterval(100), fileExists: { _ in true }))
        #expect(status.sessionInfos.map(\.state) == [.working, .idle])
        // The reported transcripts were never validated here, so after 2 minutes they count as gone.
        #expect(status.refresh(now: t0.addingTimeInterval(130), fileExists: { _ in true }))
        #expect(status.sessionInfos.isEmpty)
    }

    @Test func statusLineContextBeatsTheEstimate() {
        let status = ClaudeStatus()
        // The statusLine can arrive before the first hook.
        #expect(!status.updateContext(sessionID: "s1", percent: 37))
        status.handle(event: "SessionStart", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.contextPercent == 37)
        #expect(status.updateContext(sessionID: "s1", percent: 40))
        #expect(!status.updateContext(sessionID: "s1", percent: 40))
        #expect(status.sessionInfos.first?.contextPercent == 40)
    }

    @Test func transcriptGivesModelContextAndEnd() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects")
        let file = root.appendingPathComponent("-Users-demo-code-alpha/s1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let answer = #"{"type":"assistant","message":{"model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":1000,"cache_read_input_tokens":99000,"cache_creation_input_tokens":20000,"output_tokens":5}}}"#
        try Data(("{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n" + answer + "\n").utf8).write(to: file)

        let status = ClaudeStatus()
        status.handle(event: "UserPromptSubmit", payload: payload(extra: ["transcript_path": file.path]), now: t0)
        let reads = status.transcriptReads(now: t0.addingTimeInterval(30))
        #expect(reads.count == 1 && reads[0].wantsUsage && reads[0].wantsEnd)
        let result = TranscriptReader.read(reads[0], root: root.path)
        #expect(result.validPath != nil)
        #expect(result.usage == TranscriptReader.Usage(model: "claude-opus-5-5", contextTokens: 120_000))
        #expect(result.end == .finished)
        #expect(status.apply(reads[0], result: result, now: t0.addingTimeInterval(30)))
        let info = status.sessionInfos.first
        #expect(info?.state == .done)
        #expect(info?.model == "claude-opus-5-5")
        #expect(info?.contextPercent == 12)      // 120k of a 1M window
        #expect(status.transcripts.first?.path == result.validPath)

        // Interrupted by Esc.
        let lines: [Substring] = [#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#]
        #expect(TranscriptReader.turnEnd(lines: lines) == .interrupted)
        #expect(TranscriptReader.turnEnd(lines: [#"{"type":"user","message":{"content":"tool result"}}"#]) == .running)
    }


    @Test func runningSessionsAreFoundAtStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-projects-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("-tmp-demo-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = #"{"type":"user","cwd":"/tmp/demo-app","timestamp":"2026-11-12T10:00:00Z","message":{"role":"user","content":"fix it"}}"#
            + "\n" + #"{"type":"assistant","cwd":"/tmp/demo-app","message":{"stop_reason":"tool_use","content":[]}}"#
        try Data((running + "\n").utf8).write(to: dir.appendingPathComponent("s-run.jsonl"))
        let done = #"{"type":"assistant","cwd":"/tmp/other","message":{"stop_reason":"end_turn","content":[]}}"#
        try Data((done + "\n").utf8).write(to: dir.appendingPathComponent("s-done.jsonl"))
        let found = TranscriptReader.recent(root: root.path)
        #expect(Set(found.map(\.sessionID)) == ["s-run", "s-done"])
        let status = ClaudeStatus()
        for f in found { status.adopt(f) }
        let run = status.sessionInfos.first { $0.id == "s-run" }
        #expect(run?.state == .working && run?.project == "demo-app")
        #expect(run?.turnStartedAt == ISODate.parse("2026-11-12T10:00:00Z"))
        #expect(status.sessionInfos.first { $0.id == "s-done" }?.state == .done)
        // Old files are ignored; known sessions aren't replaced.
        #expect(TranscriptReader.recent(root: root.path, now: Date().addingTimeInterval(3600)).isEmpty)
        #expect(!status.adopt(found[0]))
    }
}
