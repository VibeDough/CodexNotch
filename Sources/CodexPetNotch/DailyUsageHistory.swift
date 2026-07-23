import Foundation

struct DailyUsagePoint: Codable, Identifiable, Equatable {
    let day: Date
    let tokens: Int

    var id: Date { day }
}

struct DailyUsageHistory {
    private static let storageKey = "dailyUsageHistory.v1"
    private let calendar = Calendar.current

    func record(tokens: Int, at date: Date = Date()) {
        guard tokens > 0 else { return }
        let day = calendar.startOfDay(for: date)
        var points = load()
        if let index = points.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            points[index] = DailyUsagePoint(day: day, tokens: max(points[index].tokens, tokens))
        } else {
            points.append(DailyUsagePoint(day: day, tokens: tokens))
        }
        save(Array(points.sorted { $0.day < $1.day }.suffix(42)))
    }

    func lastSevenDays(todayTokens: Int, now: Date = Date()) -> [DailyUsagePoint] {
        Array(recentDays(7, todayTokens: todayTokens, now: now))
    }

    func lastFourteenDays(todayTokens: Int, now: Date = Date()) -> [DailyUsagePoint] {
        Array(recentDays(14, todayTokens: todayTokens, now: now))
    }

    private func recentDays(_ count: Int, todayTokens: Int, now: Date) -> [DailyUsagePoint] {
        let today = calendar.startOfDay(for: now)
        let stored = Dictionary(uniqueKeysWithValues: load().map {
            (calendar.startOfDay(for: $0.day), $0.tokens)
        })
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let tokens = offset == 0 ? max(todayTokens, stored[day] ?? 0) : stored[day] ?? 0
            return DailyUsagePoint(day: day, tokens: tokens)
        }
    }

    private func load() -> [DailyUsagePoint] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([DailyUsagePoint].self, from: data)) ?? []
    }

    private func save(_ points: [DailyUsagePoint]) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
