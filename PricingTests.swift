#if PRICING_TESTS
import Foundation

@main
struct PricingTests {
    static func main() {
        runPricingRegressionTests()
        StatsWindowController.runOverviewRegressionTests()
        runIncrementalParserRegressionTest()
        print("Pricing and incremental parser regression tests passed")
    }

    private static func runIncrementalParserRegressionTest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pulse-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let started = """
        {"timestamp":"2026-09-23T08:00:00Z","type":"session_meta","payload":{"id":"test-session"}}
        {"timestamp":"2026-09-23T08:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"test-turn"}}

        """
        try! started.write(to: file, atomically: true, encoding: .utf8)
        let store = MetricStore(directoryURL: directory.appendingPathComponent("store"))
        let first = store.parseForTesting(file: file)
        precondition(first.completedCount == 0 && first.active)

        let completed = """
        {"timestamp":"2026-09-23T08:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"test-turn","duration_ms":1000,"time_to_first_token_ms":500}}

        """
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.seekToEnd()
        let completedBytes = Data(completed.utf8)
        let midpoint = completedBytes.count / 2
        try! handle.write(contentsOf: completedBytes.prefix(midpoint))
        let partial = store.parseForTesting(file: file)
        precondition(partial.completedCount == 0 && partial.active)
        try! handle.write(contentsOf: completedBytes.suffix(from: midpoint))
        try! handle.close()
        let second = store.parseForTesting(file: file)
        precondition(second.completedCount == 1 && !second.active)
        let third = store.parseForTesting(file: file)
        precondition(third.completedCount == 0 && !third.active, "incremental states: \(first), \(second), \(third)")
    }
}
#endif
