import AppKit
import Foundation
import Testing
import RBContract
import RBUI
@testable import RBEngine

private final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

@MainActor
private final class IconHost: EngineHost {
    var icons: [Logic.MenuBarIcon] = []
    var updates: [ViewUpdate] = []
    func menuBarIconChanged(_ icon: Logic.MenuBarIcon) { icons.append(icon) }
    func push(_ update: ViewUpdate) { updates.append(update) }
    func closePopover() {}
    func openSettings() {}
    func copyToPasteboard(_ text: String) {}
    func startHotkeyRecording(_ slot: HotkeySlot) {}
    func screenChanged(_ screen: Screen) {}
    func activate(_ app: TerminalApp) {}
    func settingsChanged(_ settings: Settings) {}
    func justEndedChanged(_ count: Int) {}
}

@MainActor
@Test func deadlineWakeRefreshesEngineAndOpenList() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.deadline.json"))
    let time = TestTime(fixture.snapshot.now)
    let engine = Engine(services: fixture.services, now: time.get(), clock: { time.get() })
    let notifications = NotificationCenter()
    engine.deadlineClockFactory = { onFire in
        DeadlineClock(now: { time.get() }, notifications: notifications, schedule: { _, _ in { } }, onFire: onFire)
    }
    let host = IconHost()
    engine.host = host
    await engine.start()
    _ = engine.popoverWillOpen(context: nil)
    #expect(host.icons.last != .overdue)
    time.set(fixture.snapshot.now.addingTimeInterval(4 * 86400))
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(engine.snapshot.now == time.get())
    #expect(host.icons.last == .overdue)
    #expect(host.updates.last?.regions.isEmpty == false)
}

@MainActor
@Test func deadlineClockFiresAtNextMidnightOnly() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
    func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }
    let time = TestTime(date(28, 12))
    let notifications = NotificationCenter()
    var scheduled: [(Date, @MainActor () -> Void)] = []
    var cancellations = 0
    var fires = 0
    let clock = DeadlineClock(now: { time.get() }, calendar: { calendar }, notifications: notifications,
                              schedule: { date, action in
        scheduled.append((date, action))
        return { cancellations += 1 }
    }, onFire: { fires += 1 })
    clock.start()
    #expect(scheduled.map(\.0) == [date(29, 0)])
    #expect(fires == 0)
    time.set(date(29, 0)); scheduled[0].1()
    #expect(fires == 1)
    #expect(scheduled.map(\.0) == [date(29, 0), date(30, 0)])
    #expect(scheduled[1].0.timeIntervalSince(scheduled[0].0) == 23 * 3600)
    time.set(date(29, 12))
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(fires == 2)
    #expect(scheduled[2].0 == date(30, 0))
    scheduled[1].1() // An invalidated timer cannot fire after wake.
    #expect(fires == 2)
    #expect(cancellations == 2)
}
