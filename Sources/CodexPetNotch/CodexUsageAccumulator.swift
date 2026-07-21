import Foundation

struct CodexUsageAccumulator {
    let dayStart: Date
    let dayEnd: Date
    private(set) var dailyTokens = 0
    private(set) var dailyTokensByModel: [String: Int] = [:]
    private(set) var latestLimit: CodexUsageLimit?
    private(set) var latestLimitDate = Date.distantPast
    private(set) var previousTotal: Int?
    private(set) var currentModel: String?

    init(
        dayStart: Date,
        dayEnd: Date,
        dailyTokens: Int = 0,
        dailyTokensByModel: [String: Int] = [:],
        latestLimit: CodexUsageLimit? = nil,
        latestLimitDate: Date = .distantPast,
        previousTotal: Int? = nil,
        currentModel: String? = nil
    ) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.dailyTokens = dailyTokens
        self.dailyTokensByModel = dailyTokensByModel
        self.latestLimit = latestLimit
        self.latestLimitDate = latestLimitDate
        self.previousTotal = previousTotal
        self.currentModel = currentModel
    }

    mutating func setModel(_ model: String) {
        currentModel = model
    }

    mutating func ingest(total: Int, at date: Date, limit: CodexUsageLimit?) {
        if date >= dayStart, date < dayEnd {
            let increment: Int
            if let previousTotal {
                increment = total >= previousTotal ? total - previousTotal : total
            } else {
                increment = total
            }
            dailyTokens += increment
            if let currentModel, increment > 0 {
                dailyTokensByModel[currentModel, default: 0] += increment
            }
        }
        previousTotal = total
        if let limit, date >= latestLimitDate {
            latestLimitDate = date
            latestLimit = limit
        }
    }
}
