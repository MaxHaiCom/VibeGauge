import Foundation

// 真实日志结构 fixture：按上游 CLI 版本留样，键名和嵌套照抄真实文件，正文/ID/路径全部替换成占位。
// 上游改了格式 → 在这里加一组新版本样本，旧版本样本保留（用户机器上新旧日志会同时存在）。
enum SelfTestFixtures {
    // Claude Code 2.1.278：一次真实回复 + 同文件里其他类型的行（都不能算进用量）
    static let claude_2_1_278 = [
        #"{"type":"permission-mode","permissionMode":"default","sessionId":"fx-session"}"#,
        #"{"type":"file-history-snapshot","messageId":"fx-m0","snapshot":{"messageId":"fx-m0","trackedFileBackups":{},"timestamp":"2026-09-18T16:00:00.000Z"},"isSnapshotUpdate":false}"#,
        #"{"parentUuid":null,"isSidechain":false,"promptId":"fx-p1","type":"user","message":{"role":"user","content":"fixture"},"uuid":"fx-u1","timestamp":"2026-09-18T16:00:01.000Z","permissionMode":"default","userType":"external","entrypoint":"cli","cwd":"/fixture","sessionId":"fx-session","version":"2.1.278","gitBranch":"main"}"#,
        #"{"parentUuid":"fx-u1","isSidechain":false,"message":{"model":"claude-opus-5","id":"fx-msg1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"fixture","signature":"fixture"}],"container":null,"stop_reason":"tool_use","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":50311,"cache_read_input_tokens":24641,"output_tokens":311,"output_tokens_details":{"thinking_tokens":76},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":50311,"ephemeral_5m_input_tokens":0}}},"requestId":"fx-req1","type":"assistant","uuid":"fx-a1","timestamp":"2026-09-18T16:00:05.000Z","userType":"external","entrypoint":"cli","cwd":"/fixture","sessionId":"fx-session","version":"2.1.278","gitBranch":"main"}"#,
        // 请求失败时 CLI 自己合成的错误回复：模型 <synthetic>、用量全 0
        #"{"parentUuid":"fx-a1","isSidechain":false,"type":"assistant","uuid":"fx-a2","timestamp":"2026-09-18T16:00:06.000Z","message":{"diagnostics":null,"id":"fx-msg2","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"output_tokens_details":null,"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":null,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}},"content":[{"type":"text","text":"fixture"}]},"isApiErrorMessage":true,"apiErrorStatus":529,"sessionId":"fx-session","version":"2.1.278"}"#,
        #"{"parentUuid":"fx-a2","isSidechain":false,"type":"system","subtype":"api_error","level":"error","error":{"message":"fixture","formatted":"fixture","connection":{"code":"ECONNRESET","message":"fixture","isSSLError":false},"isNetworkDown":false,"rateLimits":null,"noResponse":null},"retryInMs":541,"retryAttempt":1,"maxRetries":10,"source":"fixture","timestamp":"2026-09-18T16:00:07.000Z","uuid":"fx-s1","sessionId":"fx-session","version":"2.1.278"}"#,
        #"{"parentUuid":null,"logicalParentUuid":"fx-s1","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"fixture","level":"info","compactMetadata":{"trigger":"auto","preTokens":758290,"postTokens":21625,"cumulativeDroppedTokens":736665,"durationMs":326730},"uuid":"fx-s2","timestamp":"2026-09-18T16:00:08.000Z","sessionId":"fx-session","version":"2.1.278"}"#,
        #"{"type":"cost-state","sessionId":"fx-session","totalCostUSD":1.5,"modelUsage":{"claude-opus-5":{"inputTokens":2,"outputTokens":311,"cacheReadInputTokens":24641,"cacheCreationInputTokens":50311,"costUSD":1.5}}}"#,
        "",
    ].joined(separator: "\n")

    // codex-cli 0.155 / 0.156：同一次请求既写 token_usage_record 又写 token_count，只能算一次；
    // 额度只有周窗（primary 10080 分钟、secondary null）。
    static let codex_0_156 = [
        #"{"timestamp":"2026-09-18T16:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"fx-thread","id":"fx-thread","timestamp":"2026-09-18T16:00:00.000Z","cwd":"/fixture","originator":"codex_cli_rs","cli_version":"0.156.0","source":"cli","model_provider":"openai"}}"#,
        #"{"timestamp":"2026-09-18T16:00:01.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"fx-turn","started_at":1790090191,"model_context_window":258400}}"#,
        #"{"timestamp":"2026-09-18T16:00:01.000Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"fx-turn","cwd":"/fixture","model":"gpt-6-astra","effort":"xhigh"}}"#,
        #"{"timestamp":"2026-09-18T16:00:05.000Z","ordinal":13,"type":"token_usage_record","payload":{"thread_id":"fx-thread","turn_id":"fx-turn","session_id":"fx-thread","response_id":"fx-resp","usage":{"input_tokens":26552,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":234,"reasoning_output_tokens":0,"total_tokens":26786},"turn_token_usage":{"input_tokens":26552,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":234,"reasoning_output_tokens":0,"total_tokens":26786},"thread_token_usage":{"input_tokens":26552,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":234,"reasoning_output_tokens":0,"total_tokens":26786}}}"#,
        #"{"timestamp":"2026-09-18T16:00:05.000Z","ordinal":17,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":26552,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":234,"reasoning_output_tokens":0,"total_tokens":26786},"last_token_usage":{"input_tokens":26552,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":234,"reasoning_output_tokens":0,"total_tokens":26786},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":97.0,"window_minutes":10080,"resets_at":1790414260},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"prolite","rate_limit_reached_type":null}}}"#,
        #"{"timestamp":"2026-09-18T16:00:09.000Z","ordinal":137,"type":"event_msg","payload":{"type":"task_complete","turn_id":"fx-turn","last_agent_message":"fixture","started_at":1790090191,"completed_at":1790090647,"duration_ms":455654,"time_to_first_token_ms":9435}}"#,
        "",
    ].joined(separator: "\n")

    static func run() {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibegauge-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ relative: String, _ text: String) {
            let url = root.appendingPathComponent(relative)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
        }
        put(".claude/projects/fixture/s.jsonl", claude_2_1_278)
        let codexPath = ".codex/sessions/2026/09/18/s.jsonl"
        put(codexPath, codex_0_156)

        let history = UsageHistory(home: root.path)
        history.scanNowForTesting()
        let snap = history.snapshot()
        let c = snap.totals["Claude"], x = snap.totals["Codex"]
        precondition(c?.turns == 1 && c?.ctx == 2 + 50311 + 24641 && c?.out == 311, "Claude 2.1.278：错误回复/系统行/cost-state 不算用量 \(String(describing: c))")
        precondition(x?.turns == 1 && x?.ctx == 26552 && x?.out == 234, "Codex 0.156：token_usage_record 不能和 token_count 重复算 \(String(describing: x))")

        let today = ProcessScanner.shared.codexFileUsage(path: root.appendingPathComponent(codexPath).path, startOfToday: 0)
        precondition(today?.requests == 1 && today?.ctx == 26552 && today?.out == 234, "Codex 今日用量：\(String(describing: today))")

        let quota = ProcessScanner.shared.parseCodexText(codex_0_156, fallbackTime: 0).buckets["codex"]
        precondition(quota?.weekly?.usedPct == 97 && quota?.weekly?.resetsAt == 1790414260 && quota?.fiveHour == nil && quota?.plan == "prolite",
                     "Codex 0.156 额度：只有周窗")
    }
}
