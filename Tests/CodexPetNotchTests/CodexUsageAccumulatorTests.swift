import Foundation
import Testing
@testable import CodexPetNotch

@Suite struct CodexUsageAccumulatorTests {
    @Test func countsOnlyIncreaseAfterStartOfDay() {
        let start = Date(timeIntervalSince1970: 86_400)
        var accumulator = CodexUsageAccumulator(dayStart: start, dayEnd: start.addingTimeInterval(86_400))

        accumulator.ingest(total: 1_000, at: start.addingTimeInterval(-1), limit: nil)
        accumulator.ingest(total: 1_250, at: start.addingTimeInterval(10), limit: nil)
        accumulator.ingest(total: 1_400, at: start.addingTimeInterval(20), limit: nil)

        #expect(accumulator.dailyTokens == 400)
    }

    @Test func countsFromZeroForConversationCreatedToday() {
        let start = Date(timeIntervalSince1970: 86_400)
        var accumulator = CodexUsageAccumulator(dayStart: start, dayEnd: start.addingTimeInterval(86_400))

        accumulator.ingest(total: 300, at: start.addingTimeInterval(10), limit: nil)
        accumulator.ingest(total: 450, at: start.addingTimeInterval(20), limit: nil)

        #expect(accumulator.dailyTokens == 450)
    }

    @Test func handlesCounterReset() {
        let start = Date(timeIntervalSince1970: 86_400)
        var accumulator = CodexUsageAccumulator(dayStart: start, dayEnd: start.addingTimeInterval(86_400))

        accumulator.ingest(total: 900, at: start.addingTimeInterval(-1), limit: nil)
        accumulator.ingest(total: 100, at: start.addingTimeInterval(10), limit: nil)

        #expect(accumulator.dailyTokens == 100)
    }

    @Test func keepsLatestRateLimitFromBeforeToday() {
        let start = Date(timeIntervalSince1970: 86_400)
        let resetAt = start.addingTimeInterval(7 * 86_400)
        let limit = CodexUsageLimit(usedPercent: 0, resetAt: resetAt, planType: "plus")
        var accumulator = CodexUsageAccumulator(dayStart: start, dayEnd: start.addingTimeInterval(86_400))

        accumulator.ingest(total: 500, at: start.addingTimeInterval(-60), limit: limit)

        #expect(accumulator.dailyTokens == 0)
        #expect(accumulator.latestLimit == limit)
    }
}
