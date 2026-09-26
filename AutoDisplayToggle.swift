import Cocoa
import CoreGraphics
import ApplicationServices // برای دسترسی به مجوزهای کیبورد

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var isAutoEnabled = true

    // شناسه‌ی مانیتور داخلی بعد از هر sleep/wake عوض می‌شود،
    // پس این مقدار فقط یک کش است و قبل از هر عملیات دوباره پیدا می‌شود.
    var internalDisplayID: CGDirectDisplayID = 0

    var savedBrightness: Float = 0.5
    var isSleeping = false
    var isApplying = false
    var failureCount = 0
    let maxFailures = 6

    var reconcileWorkItem: DispatchWorkItem?
    var reconcileTimer: Timer?
    var lastKnownInternalActive: Bool?
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        resolveInternalDisplay()
        captureBrightness()
        setupMenu()
        setupPowerObservers()
        setupGlobalShortcuts() // ناظر کیبورد
        setupTerminationHandlers()
        startMonitoring()
        sendNotification(title: "AutoDisplayToggle", message: "🖥️ Service is now active in the menu bar.")
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Toggle")
        }

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Status: Auto Enabled", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 1
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let toggleMenuItem = NSMenuItem(title: "Pause Auto-Toggle", action: #selector(toggleAuto), keyEquivalent: "p")
        toggleMenuItem.tag = 2
        menu.addItem(toggleMenuItem)

        let resetMenuItem = NSMenuItem(title: "Reset Displays (Panic)", action: #selector(manualReset), keyEquivalent: "r")
        menu.addItem(resetMenuItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func toggleAuto() {
        isAutoEnabled.toggle()
        let menu = statusItem.menu!

        menu.item(withTag: 1)?.title = isAutoEnabled ? "Status: Auto Enabled" : "Status: Paused"
        menu.item(withTag: 2)?.title = isAutoEnabled ? "Pause Auto-Toggle" : "Resume Auto-Toggle"

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isAutoEnabled ? "display.2" : "display", accessibilityDescription: nil)
        }

        // هر بار که کاربر دستی دخالت می‌کند، وضعیت داخلی برنامه را از نو می‌سنجیم
        isSleeping = false
        failureCount = 0

        if isAutoEnabled {
            sendNotification(title: "Auto-Toggle Resumed", message: "⚡️ Automated display management is ON.")
            scheduleReconcile(after: 0.5)
        } else {
            sendNotification(title: "Auto-Toggle Paused", message: "⏸️ Automated display management is OFF.")
            _ = setInternalEnabled(true)
        }
    }

    // ---------- قابلیت تنظیم میانبرهای کیبورد ----------
    func setupGlobalShortcuts() {
        // درخواست مجوز دسترسی به مانیتورینگ کیبورد
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(opts)

        if !accessEnabled {
            sendNotification(title: "Permission Required", message: "⚠️ Please grant Accessibility access in System Settings for shortcuts to work.")
        }

        // ناظر برای زمانی که برنامه در پس‌زمینه است
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        // ناظر برای زمانی که برنامه فوکوس دارد
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            self?.handleKeyEvent(event)
            return event
        }
    }

    func handleKeyEvent(_ event: NSEvent) {
        // بررسی فشرده شدن همزمان کلیدهای Control + Option + Command
        let hasCommand = event.modifierFlags.contains(.command)
        let hasControl = event.modifierFlags.contains(.control)
        let hasOption = event.modifierFlags.contains(.option)

        if hasCommand && hasControl && hasOption {
            if let char = event.charactersIgnoringModifiers?.lowercased() {
                if char == "d" {
                    // Control + Option + Command + D (برای غیرفعال کردن)
                    if self.isAutoEnabled {
                        self.toggleAuto()
                    }
                } else if char == "e" {
                    // Control + Option + Command + E (برای فعال کردن)
                    if !self.isAutoEnabled {
                        self.toggleAuto()
                    }
                }
            }
        }
    }
    // ---------------------------------------------------------

    @objc func manualReset() {
        if isAutoEnabled { toggleAuto() } // toggleAuto خودش مانیتور داخلی را روشن می‌کند
        else { _ = setInternalEnabled(true) }
        sendNotification(title: "Panic Reset", message: "✅ Internal display restored successfully.")
    }

    @objc func quitApp() {
        isAutoEnabled = false
        reconcileTimer?.invalidate()
        reconcileWorkItem?.cancel()
        CGDisplayRemoveReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
        _ = setInternalEnabled(true)
        NSApplication.shared.terminate(nil)
    }

    // اگر برنامه بدون بازگرداندن نور بسته شود، مانیتور داخلی سیاه و خاموش می‌ماند.
    // پس در همه‌ی مسیرهای خروج (منو، Apple Event، SIGTERM) آن را برمی‌گردانیم.
    func applicationWillTerminate(_ aNotification: Notification) {
        restoreBeforeExit()
    }

    func restoreBeforeExit() {
        isAutoEnabled = false
        reconcileTimer?.invalidate()
        reconcileWorkItem?.cancel()
        _ = setInternalEnabled(true)
    }

    func setupTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreBeforeExit()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func sendNotification(title: String, message: String) {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\""]
            try? task.run()
        }
    }

    // ---------- شناسایی مانیتورها ----------

    // شناسه‌ی مانیتور داخلی را از نو پیدا می‌کند. این کار باید قبل از هر عملیات انجام شود،
    // چون macOS بعد از بیدار شدن یا وصل/قطع شدن مانیتور، شناسه‌ها را عوض می‌کند.
    @discardableResult
    func resolveInternalDisplay() -> CGDirectDisplayID {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        if CGGetOnlineDisplayList(16, &displays, &displayCount) == .success {
            for i in 0..<Int(displayCount) where CGDisplayIsBuiltin(displays[i]) != 0 {
                internalDisplayID = displays[i]
                return internalDisplayID
            }
        }

        // اگر مانیتور داخلی در لیست نبود (مثلاً حالت clamshell)، فقط در صورتی
        // از شناسه‌ی قبلی استفاده می‌کنیم که هنوز معتبر و داخلی باشد.
        if internalDisplayID != 0 && CGDisplayIsBuiltin(internalDisplayID) != 0 {
            return internalDisplayID
        }

        internalDisplayID = 0
        return 0
    }

    // تشخیص مانیتور خارجی بر اساس builtin بودن، نه بر اساس شناسه‌ی کش‌شده
    func hasActiveExternal() -> Bool {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &displays, &displayCount) == .success else { return false }

        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displays[i]) == 0 && CGDisplayIsActive(displays[i]) != 0 {
                return true
            }
        }
        return false
    }

    func captureBrightness() {
        guard internalDisplayID != 0 else { return }
        var level: Float = 0
        if DisplayServicesGetBrightness(internalDisplayID, &level) == 0 && level > 0.01 {
            savedBrightness = level
        }
    }

    // غیرفعال کردن مانیتور به تنهایی بک‌لایت پنل را خاموش نمی‌کند؛
    // نور پس‌زمینه مستقل از فعال بودن مانیتور قابل تنظیم است و ممکن است
    // بعد از بیداری یا توسط سنسور نور محیط دوباره روشن شود.
    @discardableResult
    func enforceZeroBrightness(_ id: CGDirectDisplayID) -> Bool {
        var level: Float = 0
        if DisplayServicesGetBrightness(id, &level) == 0 {
            if level <= 0.001 { return true } // از قبل صفر است
            if level > 0.01 { savedBrightness = level } // ترجیح کاربر را نگه می‌داریم
        }
        return DisplayServicesSetBrightness(id, 0.0) == 0
    }

    // ---------- اعمال وضعیت ----------

    func setInternalEnabled(_ enabled: Bool) -> Bool {
        let id = resolveInternalDisplay()
        guard id != 0 else { return false }

        // قبل از خاموش کردن نور را صفر می‌کنیم تا در لحظه‌ی تغییر، پنل روشن نماند
        if !enabled { enforceZeroBrightness(id) }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }

        guard CGSConfigureDisplayEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return false }

        if enabled {
            // کف امنیتی تا در صورت خراب بودن مقدار ذخیره‌شده، صفحه سیاه نماند
            return DisplayServicesSetBrightness(id, max(savedBrightness, 0.05)) == 0
        }
        return enforceZeroBrightness(id)
    }

    // تنها نقطه‌ی تصمیم‌گیری برنامه: وضعیت واقعی را با وضعیت مطلوب مقایسه می‌کند.
    // چون بر پایه‌ی وضعیت کار می‌کند نه رویداد، هیچ‌وقت در حالت غلط گیر نمی‌کند
    // و اعمال دوباره‌اش هم بی‌خطر است.
    @objc func reconcile() {
        guard isAutoEnabled, !isSleeping, !isApplying else { return }

        let id = resolveInternalDisplay()
        guard id != 0 else { return }

        let actual = CGDisplayIsActive(id) != 0
        let desired = !hasActiveExternal()

        // اطلاع‌رسانی فقط وقتی وضعیت واقعی عوض شده، نه در هر بار بررسی
        if let last = lastKnownInternalActive, last != actual {
            if actual {
                sendNotification(title: "Display Restored", message: "☀️ Internal display is ON.")
            } else {
                sendNotification(title: "Display Disabled", message: "🌑 Internal display is now OFF.")
            }
        }
        lastKnownInternalActive = actual

        guard actual != desired else {
            failureCount = 0
            // وضعیت فعال/غیرفعال درست است، ولی بک‌لایت ممکن است دوباره روشن شده باشد
            if !desired { enforceZeroBrightness(id) }
            return
        }

        guard failureCount < maxFailures else { return }

        isApplying = true
        let ok = setInternalEnabled(desired)
        isApplying = false

        failureCount = ok ? 0 : failureCount + 1
        // نتیجه در بررسی بعدی تأیید می‌شود
        scheduleReconcile(after: ok ? 2.0 : 5.0)
    }

    // بررسی با تأخیر و بدون انباشت؛ هر درخواست جدید قبلی را لغو می‌کند
    func scheduleReconcile(after delay: TimeInterval) {
        reconcileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // ---------- رویدادهای سیستم ----------

    func setupPowerObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = true
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }

        // تغییر آرایش مانیتورها (وصل/قطع شدن، تغییر رزولوشن)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = false
            self?.failureCount = 0
            self?.scheduleReconcile(after: 2.0)
        }
    }

    @objc func handleSleep() {
        isSleeping = true
        reconcileWorkItem?.cancel()
        guard isAutoEnabled else { return }
        // قبل از خواب سیستم، مانیتور داخلی را روشن می‌کنیم تا مک‌اواس با حالت عادی بخوابد
        _ = setInternalEnabled(true)
        lastKnownInternalActive = nil
    }

    func handleWake() {
        isSleeping = false
        failureCount = 0
        // شناسه‌ی مانیتور داخلی بعد از بیداری عوض شده؛ کش را دور می‌ریزیم
        internalDisplayID = 0
        lastKnownInternalActive = nil
        resolveInternalDisplay()
        // چند بار در بازه‌های مختلف بررسی می‌کنیم چون مانیتور خارجی ممکن است دیرتر برگردد
        scheduleReconcile(after: 4.0)
    }

    func startMonitoring() {
        CGDisplayRegisterReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())

        // تور ایمنی: هر ۵ ثانیه وضعیت واقعی بررسی می‌شود.
        // اگر رویدادی از دست برود یا اعمال تنظیمات شکست بخورد، برنامه خودش را ترمیم می‌کند
        // و دیگر لازم نیست برنامه بسته و دوباره باز شود.
        let timer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(reconcile), userInfo: nil, repeats: true)
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer

        scheduleReconcile(after: 1.0)
    }
}

// طبق مستندات اپل نباید داخل این callback پیکربندی مانیتورها را تغییر داد،
// پس فقط یک بررسی با تأخیر روی صف اصلی زمان‌بندی می‌کنیم.
let displayCallback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
    guard let userInfo = userInfo else { return }
    if flags.contains(.beginConfigurationFlag) { return }

    let monitor = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.isSleeping = false
        monitor.internalDisplayID = 0 // شناسه ممکن است عوض شده باشد
        monitor.failureCount = 0
        monitor.scheduleReconcile(after: 2.0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
