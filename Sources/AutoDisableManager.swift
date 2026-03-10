import Foundation

final class AutoDisableManager {
    var onAutoDisable: (() -> Void)?
    var onTimerChanged: (() -> Void)?

    private var workItem: DispatchWorkItem?
    private var displayTimer: Timer?
    private var fireDate: Date?

    var isActive: Bool { fireDate != nil }

    var remainingText: String {
        guard let fireDate else { return "Off" }
        let minutes = max(0, Int(fireDate.timeIntervalSinceNow / 60) + 1)
        if minutes <= 0 { return "Off" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainingMinutes)m"
    }

    func schedule(minutes: Int) {
        cancel(notify: false)
        let seconds = TimeInterval(minutes * 60)
        fireDate = Date().addingTimeInterval(seconds)

        let item = DispatchWorkItem { [weak self] in
            self?.fireDate = nil
            self?.displayTimer?.invalidate()
            self?.displayTimer = nil
            self?.onAutoDisable?()
            self?.onTimerChanged?()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)

        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.onTimerChanged?()
        }

        onTimerChanged?()
    }

    func cancel(notify: Bool = true) {
        workItem?.cancel()
        workItem = nil
        displayTimer?.invalidate()
        displayTimer = nil
        fireDate = nil
        if notify {
            onTimerChanged?()
        }
    }
}
