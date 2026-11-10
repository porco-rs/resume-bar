import AppKit
import Foundation

/// One local-midnight timer, rearmed after it fires or the Mac wakes.
@MainActor
final class DeadlineClock: NSObject {
    typealias Schedule = @MainActor (Date, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let now: @Sendable () -> Date
    private let calendar: () -> Calendar
    private let schedule: Schedule
    private let onFire: @MainActor () -> Void
    private let notifications: NotificationCenter
    private var cancelTimer: (@MainActor () -> Void)?
    private var generation = 0

    init(now: @escaping @Sendable () -> Date = { Date() },
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         schedule: @escaping Schedule = { date, action in
             let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
                 Task { @MainActor in action() }
             }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         },
         onFire: @escaping @MainActor () -> Void) {
        self.now = now
        self.calendar = calendar
        self.notifications = notifications
        self.schedule = schedule
        self.onFire = onFire
    }

    func start() {
        notifications.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        arm()
    }

    @objc private func woke() { fire() }

    private func arm() {
        cancelTimer?()
        generation += 1
        let token = generation
        let cal = calendar()
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now()))!
        cancelTimer = schedule(midnight) { [weak self] in
            guard let self, self.generation == token else { return }
            self.fire()
        }
    }

    private func fire() {
        arm()
        onFire()
    }
}
