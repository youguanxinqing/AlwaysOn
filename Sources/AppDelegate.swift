import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let powerManager = PowerManager()
    private let batteryMonitor = BatteryMonitor()
    private let loginItemManager = LoginItemManager()
    private let autoDisableManager = AutoDisableManager()
    private var isDesktop = false

    // Menu items that need updating
    private var toggleMenuItem: NSMenuItem!
    private var autoDisableMenuItem: NSMenuItem!
    private var cancelTimerSeparator: NSMenuItem!
    private var cancelTimerMenuItem: NSMenuItem!
    private var batteryMenuItem: NSMenuItem!
    private var powerSourceMenuItem: NSMenuItem!
    private var batterySeparator: NSMenuItem!
    private var loginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !PrivilegeManager.hasPasswordlessPmset() {
            let granted = PrivilegeManager.requestPrivileges()
            if !granted {
                let alert = NSAlert()
                alert.messageText = "Permission Required"
                alert.informativeText = "AlwaysOn cannot function without pmset access. The app will quit."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
        }

        // Detect desktop Mac (no battery)
        let info = batteryMonitor.currentInfo()
        isDesktop = !info.hasBattery

        setupStatusItem()
        setupBatteryMonitor()
        setupAutoDisable()
        updateMenuState()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bolt.slash.fill", accessibilityDescription: "AlwaysOn")
        button.imagePosition = .imageLeading

        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: "Enable AlwaysOn", action: #selector(toggleAlwaysOn), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        autoDisableMenuItem = NSMenuItem(title: "Auto-disable: Off", action: nil, keyEquivalent: "")
        autoDisableMenuItem.submenu = buildAutoDisableSubmenu()
        menu.addItem(autoDisableMenuItem)

        batterySeparator = NSMenuItem.separator()
        menu.addItem(batterySeparator)

        batteryMenuItem = NSMenuItem(title: "Battery: --", action: nil, keyEquivalent: "")
        batteryMenuItem.isEnabled = false
        menu.addItem(batteryMenuItem)

        powerSourceMenuItem = NSMenuItem(title: "Power: --", action: nil, keyEquivalent: "")
        powerSourceMenuItem.isEnabled = false
        menu.addItem(powerSourceMenuItem)

        // Hide battery items on desktop Macs
        if isDesktop {
            batterySeparator.isHidden = true
            batteryMenuItem.isHidden = true
            powerSourceMenuItem.isHidden = true
        }

        menu.addItem(NSMenuItem.separator())

        loginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Auto-disable

    private func setupAutoDisable() {
        autoDisableManager.onAutoDisable = { [weak self] in
            DispatchQueue.main.async {
                self?.powerManager.disable()
                self?.updateMenuState()
            }
        }
        autoDisableManager.onTimerChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateAutoDisableMenuItem()
            }
        }
    }

    private func buildAutoDisableSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let options = [(30, "In 30 minutes"), (60, "In 1 hour"), (120, "In 2 hours"), (240, "In 4 hours")]
        for (minutes, title) in options {
            let item = NSMenuItem(title: title, action: #selector(scheduleAutoDisable(_:)), keyEquivalent: "")
            item.tag = minutes
            item.target = self
            submenu.addItem(item)
        }

        let customItem = NSMenuItem(title: "Custom...", action: #selector(promptCustomTime), keyEquivalent: "")
        customItem.target = self
        submenu.addItem(customItem)

        cancelTimerSeparator = NSMenuItem.separator()
        cancelTimerSeparator.isHidden = true
        submenu.addItem(cancelTimerSeparator)

        cancelTimerMenuItem = NSMenuItem(title: "Cancel Timer", action: #selector(cancelAutoDisable), keyEquivalent: "")
        cancelTimerMenuItem.target = self
        cancelTimerMenuItem.isHidden = true
        submenu.addItem(cancelTimerMenuItem)

        return submenu
    }

    private func updateAutoDisableMenuItem() {
        autoDisableMenuItem.title = "Auto-disable: \(autoDisableManager.remainingText)"
        let active = autoDisableManager.isActive
        cancelTimerSeparator.isHidden = !active
        cancelTimerMenuItem.isHidden = !active
    }

    @objc private func scheduleAutoDisable(_ sender: NSMenuItem) {
        autoDisableManager.schedule(minutes: sender.tag)
    }

    @objc private func promptCustomTime() {
        let alert = NSAlert()
        alert.messageText = "Auto-disable After"
        alert.informativeText = "Enter the number of minutes:"
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "e.g. 90"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            guard let minutes = Int(textField.stringValue.trimmingCharacters(in: .whitespaces)),
                  minutes > 0 else { return }
            autoDisableManager.schedule(minutes: minutes)
        }
    }

    @objc private func cancelAutoDisable() {
        autoDisableManager.cancel()
    }

    // MARK: - Battery Monitor

    private func setupBatteryMonitor() {
        batteryMonitor.onBatteryUpdate = { [weak self] percentage, isOnAC in
            DispatchQueue.main.async {
                self?.updateBatteryDisplay(percentage: percentage, isOnAC: isOnAC)
            }
        }

        batteryMonitor.onCriticalBattery = { [weak self] isClamshellClosed in
            DispatchQueue.main.async {
                self?.handleCriticalBattery(clamshellClosed: isClamshellClosed)
            }
        }

        batteryMonitor.start()
    }

    private func updateBatteryDisplay(percentage: Int, isOnAC: Bool) {
        guard !isDesktop else { return }

        let pctText = percentage >= 0 ? "\(percentage)%" : "--"
        batteryMenuItem.title = "Battery: \(pctText)"
        powerSourceMenuItem.title = "Power: \(isOnAC ? "AC" : "Battery")"

        if powerManager.isEnabled && percentage >= 0 {
            statusItem.button?.title = " \(pctText)"
        }
    }

    private func handleCriticalBattery(clamshellClosed: Bool) {
        guard powerManager.isEnabled else { return }

        if clamshellClosed {
            autoDisableManager.cancel(notify: false)
            powerManager.disable()
            powerManager.sleepNow()
            updateMenuState()
        } else {
            sendCriticalNotification()
        }
    }

    private func sendCriticalNotification() {
        let content = UNMutableNotificationContent()
        content.title = "AlwaysOn — Critical Battery"
        content.body = "Battery at 5% or below. Connect charger or disable AlwaysOn."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "critical-battery",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - State Management

    private func updateMenuState() {
        let enabled = powerManager.isEnabled

        toggleMenuItem.title = enabled ? "Disable AlwaysOn" : "Enable AlwaysOn"
        loginMenuItem.state = loginItemManager.isEnabled ? .on : .off

        if enabled {
            statusItem.button?.image = NSImage(
                systemSymbolName: "bolt.fill",
                accessibilityDescription: "AlwaysOn Active"
            )
            if !isDesktop {
                let info = batteryMonitor.currentInfo()
                let pctText = info.percentage >= 0 ? "\(info.percentage)%" : "--"
                statusItem.button?.title = " \(pctText)"
            }
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "bolt.slash.fill",
                accessibilityDescription: "AlwaysOn Inactive"
            )
            statusItem.button?.title = ""
        }

        if !isDesktop {
            let info = batteryMonitor.currentInfo()
            let pctText = info.percentage >= 0 ? "\(info.percentage)%" : "--"
            batteryMenuItem.title = "Battery: \(pctText)"
            powerSourceMenuItem.title = "Power: \(info.isOnAC ? "AC" : "Battery")"
        }
    }

    // MARK: - Actions

    @objc private func toggleAlwaysOn() {
        if powerManager.isEnabled {
            autoDisableManager.cancel(notify: false)
            powerManager.disable()
        } else {
            powerManager.enable()
        }
        updateMenuState()
        updateAutoDisableMenuItem()
    }

    @objc private func toggleLoginItem() {
        let newState = !loginItemManager.isEnabled
        loginItemManager.setEnabled(newState)
        loginMenuItem.state = newState ? .on : .off
    }

    @objc private func quitApp() {
        autoDisableManager.cancel(notify: false)
        if powerManager.isEnabled {
            powerManager.disable()
        }
        batteryMonitor.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoDisableManager.cancel(notify: false)
        if powerManager.isEnabled {
            powerManager.disable()
        }
        batteryMonitor.stop()
    }
}
