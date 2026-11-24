import Foundation
import Testing
@testable import OpenLens

struct OCHomeGroupingTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-11-24 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_795_608_000)

    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    private func session(_ id: String, updated: Date, dir: String? = "/home/docker") -> OCSession {
        OCSession(id: id, directory: dir, title: id, time: OCSessionTime(created: ms(updated), updated: ms(updated)))
    }

    private func groups(_ sessions: [OCSession]) -> [OCHomeGroup] {
        OCHomeGrouping.groups(for: sessions, now: now, calendar: calendar)
    }

    @Test func splitsTodayYesterdayOlder() {
        let result = groups([
            session("a", updated: now.addingTimeInterval(-3600)),
            session("b", updated: now.addingTimeInterval(-86_400)),
            session("c", updated: now.addingTimeInterval(-5 * 86_400)),
        ])
        #expect(result.map(\.title) == [AppText.ocToday, AppText.ocYesterday, AppText.ocOlder])
        #expect(result.map { $0.sessions.map(\.id) } == [["a"], ["b"], ["c"]])
    }

    @Test func onlyOlderSessionsAreTitledRecentSessions() {
        let result = groups([session("c", updated: now.addingTimeInterval(-9 * 86_400))])
        #expect(result.map(\.title) == [AppText.ocRecentSessions])
    }

    @Test func midnightBoundary() {
        let startOfToday = calendar.startOfDay(for: now)
        let result = groups([
            session("justAfter", updated: startOfToday),
            session("justBefore", updated: startOfToday.addingTimeInterval(-1)),
        ])
        #expect(result.first { $0.kind == .today }?.sessions.map(\.id) == ["justAfter"])
        #expect(result.first { $0.kind == .yesterday }?.sessions.map(\.id) == ["justBefore"])
    }

    @Test func sortsNewestFirstAndBreaksTiesById() {
        let t = now.addingTimeInterval(-600)
        let result = groups([
            session("b", updated: t),
            session("c", updated: now.addingTimeInterval(-60)),
            session("a", updated: t),
        ])
        #expect(result.first?.sessions.map(\.id) == ["c", "a", "b"])
    }

    @Test func projectKeyAndNameFollowDirectory() {
        let a = session("a", updated: now, dir: "/home/docker")
        let b = session("b", updated: now, dir: "/srv/other")
        #expect(OCHomeGrouping.projectKey(for: a) != OCHomeGrouping.projectKey(for: b))
        #expect(OCHomeGrouping.projectName(for: a) == "docker")
        #expect(OCHomeGrouping.monogram("docker") == "D")
        let kept = [a, b].filter { OCHomeGrouping.projectKey(for: $0) == OCHomeGrouping.projectKey(for: b) }
        #expect(kept.map(\.id) == ["b"])
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        let s = OCSession(id: "x", title: "Sondé projekt", time: OCSessionTime(created: 0, updated: 0))
        #expect(OCHomeGrouping.matches(s, query: "sonde"))
        #expect(OCHomeGrouping.matches(s, query: "PROJ"))
        #expect(!OCHomeGrouping.matches(s, query: "zzz"))
    }
}
