import Foundation

struct CodexUsageAccumulator {
    let dayStart: Date
    let dayEnd: Date
    private(set) var dailyTokens = 0
    private(set) var latestLimit: CodexUsageLimit?
    private(set) var latestLimitDate = Date.distantPast
    private(set) var previousTotal: Int?

    init(
        dayStart: Date,
        dayEnd: Date,
        dailyTokens: Int = 0,
        latestLimit: CodexUsageLimit? = nil,
        latestLimitDate: Date = .distantPast,
        previousTotal: Int? = nil
    ) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.dailyTokens = dailyTokens
        self.latestLimit = latestLimit
        self.latestLimitDate = latestLimitDate
        self.previousTotal = previousTotal
    }

    mutating func ingest(total: Int, at date: Date, limit: CodexUsageLimit?) {
        if date >= dayStart, date < dayEnd {
            if let previousTotal {
                dailyTokens += total >= previousTotal ? total - previousTotal : total
            } else {
                dailyTokens += total
            }
        }
        previousTotal = total
        if let limit, date >= latestLimitDate {
            latestLimitDate = date
            latestLimit = limit
        }
    }
}
