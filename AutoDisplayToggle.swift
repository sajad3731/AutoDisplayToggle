import Cocoa
import CoreGraphics
import UserNotifications
import ServiceManagement
import Carbon.HIToolbox // برای میانبرهای سراسری

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

// این توابع در سمت C مقدار ۳۲ بیتی برمی‌گردانند؛ اگر Int (۶۴ بیتی) اعلام شوند
// بیت‌های بالایی نامعتبرند و مقایسه‌ی نتیجه با صفر غیرقابل‌اتکا می‌شود.
@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

// شناسه‌های میانبرها. امضا فقط باید برای این برنامه یکتا باشد.
let hotKeySignature = OSType(0x41445447) // 'ADTG'
let hotKeyIDTurnOff: UInt32 = 1
let hotKeyIDTurnOn: UInt32 = 2

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var isEnabled = true

    // شناسه‌ی مانیتور داخلی بعد از هر sleep/wake عوض می‌شود،
    // پس این مقدار فقط یک کش است و قبل از هر عملیات دوباره پیدا می‌شود.
    var internalDisplayID: CGDirectDisplayID = 0

    var savedBrightness: Float = 0.5
    var isSleeping = false
    var isApplying = false
    var failureCount = 0
    let maxFailures = 6
    // بعد از چند شکست پیاپی کمی صبر می‌کنیم، ولی برای همیشه دست نمی‌کشیم
    var lastFailureAt: Date?
    let failureCooldown: TimeInterval = 60
    var reportedGivingUp = false

    var reconcileWorkItem: DispatchWorkItem?
    var reconcileTimer: Timer?
    var lastKnownInternalActive: Bool?
    var signalSources: [DispatchSourceSignal] = []
    var useUserNotifications = false
    var isWatchingDisplays = false
    var hotKeyRefs: [EventHotKeyRef] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        resolveInternalDisplay()
        captureBrightness()
        setupMenu()
        setupPowerObservers()
        setupGlobalShortcuts() // میانبرهای سراسری
        setupTerminationHandlers()
        startMonitoring()
        // پیام خوش‌آمد بعد از تعیین‌تکلیف مجوز نوتیفیکیشن فرستاده می‌شود
        // تا اولین نوتیفیکیشن هم با آیکن خود برنامه نمایش داده شود.
        setupNotifications {
            self.sendNotification(title: "AutoDisplayToggle", message: "🖥️ Service is now active in the menu bar.")
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // آیتم «Start at Login» در مک‌اواس قدیمی‌تر غیرفعال می‌ماند،
        // پس فعال/غیرفعال بودن آیتم‌ها را خودمان مدیریت می‌کنیم.
        menu.autoenablesItems = false
        menu.delegate = self

        let statusMenuItem = NSMenuItem(title: "Status: On", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 1
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // میانبر سراسری جداگانه رزرو شده، پس اینجا فقط در عنوان نوشته
        // می‌شود و به‌عنوان keyEquivalent ثبت نمی‌شود.
        let toggleMenuItem = NSMenuItem(title: "Turn Off (⌃⌥⌘D)", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleMenuItem.tag = 2
        menu.addItem(toggleMenuItem)

        let resetMenuItem = NSMenuItem(title: "Reset Displays (Panic)", action: #selector(manualReset), keyEquivalent: "r")
        menu.addItem(resetMenuItem)
        menu.addItem(NSMenuItem.separator())

        let loginMenuItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.tag = 3
        menu.addItem(loginMenuItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        updateMenuState()
        refreshLoginItemState()
    }

    func updateMenuState() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isEnabled ? "display.2" : "display",
                                   accessibilityDescription: isEnabled ? "Display Toggle: on" : "Display Toggle: off")
        }

        guard let menu = statusItem.menu else { return }
        menu.item(withTag: 1)?.title = isEnabled ? "Status: On" : "Status: Off"
        menu.item(withTag: 2)?.title = isEnabled ? "Turn Off (⌃⌥⌘D)" : "Turn On (⌃⌥⌘E)"
    }

    // ---------- اجرا هنگام ورود به سیستم ----------

    @objc func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }

        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                sendNotification(title: "Start at Login",
                                 message: "⛔️ AutoDisplayToggle will no longer start automatically.")
            case .requiresApproval:
                // خود مک‌اواس اجازه را نگه داشته؛ کاربر باید در تنظیمات تأیید کند
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                sendNotification(title: "Start at Login",
                                 message: "✅ AutoDisplayToggle will start automatically at login.")
            }
        } catch {
            sendNotification(title: "Start at Login Failed", message: "⚠️ \(error.localizedDescription)")
        }

        refreshLoginItemState()
    }

    func refreshLoginItemState() {
        guard let item = statusItem.menu?.item(withTag: 3) else { return }

        guard #available(macOS 13.0, *) else {
            item.title = "Start at Login (needs macOS 13)"
            item.isEnabled = false
            item.state = .off
            return
        }

        item.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            item.title = "Start at Login"
            item.state = .on
        case .requiresApproval:
            item.title = "Start at Login (approve in System Settings)"
            item.state = .mixed
        default:
            item.title = "Start at Login"
            item.state = .off
        }
    }

    @objc func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    // خاموش کردن یعنی برنامه واقعاً کاری نکند: تایمر و ناظر مانیتورها متوقف
    // می‌شوند و مانیتور داخلی برمی‌گردد. آیتم نوار منو و میانبرها زنده
    // می‌مانند، چون در غیر این صورت هیچ‌چیز نبود که میانبر روشن‌کردن را
    // بشنود.
    func setEnabled(_ enabled: Bool, notify: Bool = true) {
        isEnabled = enabled
        // هر بار که کاربر دستی دخالت می‌کند، وضعیت داخلی برنامه را از نو می‌سنجیم
        isSleeping = false
        resetFailureState()
        updateMenuState()

        if enabled {
            startMonitoring()
            if notify {
                sendNotification(title: "AutoDisplayToggle On",
                                 message: "⚡️ Automatic display switching is active.")
            }
            scheduleReconcile(after: 0.5)
        } else {
            stopMonitoring()
            _ = setInternalEnabled(true)
            lastKnownInternalActive = nil
            if notify {
                sendNotification(title: "AutoDisplayToggle Off",
                                 message: "⏸️ Idle. Press ⌃⌥⌘E to turn it back on.")
            }
        }
    }

    // ---------- میانبرهای سراسری ----------

    // RegisterEventHotKey میانبر را در سطح سیستم رزرو می‌کند و هیچ مجوز
    // Accessibility نمی‌خواهد. ناظر رویدادی که قبلاً استفاده می‌شد بدون آن
    // مجوز بی‌صدا هیچ‌وقت اجرا نمی‌شد، یعنی میانبرها ظاهراً کار نمی‌کردند؛
    // ضمن اینکه بعد از دادن مجوز هم تا ری‌استارت برنامه فعال نمی‌شد.
    func setupGlobalShortcuts() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            hotKeyHandler,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            nil)

        let offRegistered = registerHotKey(id: hotKeyIDTurnOff, keyCode: UInt32(kVK_ANSI_D))
        let onRegistered = registerHotKey(id: hotKeyIDTurnOn, keyCode: UInt32(kVK_ANSI_E))

        if !offRegistered || !onRegistered {
            sendNotification(title: "Shortcut Unavailable",
                             message: "⚠️ ⌃⌥⌘D / ⌃⌥⌘E are already claimed by another app.")
        }
    }

    func registerHotKey(id: UInt32, keyCode: UInt32) -> Bool {
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(keyCode,
                                         UInt32(controlKey | optionKey | cmdKey),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)

        guard status == noErr, let ref = ref else { return false }
        hotKeyRefs.append(ref)
        return true
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case hotKeyIDTurnOff:
            if isEnabled { setEnabled(false) }
        case hotKeyIDTurnOn:
            if !isEnabled { setEnabled(true) }
        default:
            break
        }
    }
    // ---------------------------------------------------------

    @objc func manualReset() {
        // setEnabled(false) خودش مانیتور داخلی را برمی‌گرداند؛ اطلاع‌رسانی‌اش را
        // خاموش می‌کنیم تا دو نوتیفیکیشن پشت سر هم نیاید.
        if isEnabled { setEnabled(false, notify: false) }
        else { _ = setInternalEnabled(true) }
        sendNotification(title: "Panic Reset",
                         message: "✅ Internal display restored. Press ⌃⌥⌘E to turn switching back on.")
    }

    @objc func quitApp() {
        restoreBeforeExit()
        NSApplication.shared.terminate(nil)
    }

    // اگر برنامه بدون بازگرداندن نور بسته شود، مانیتور داخلی سیاه و خاموش می‌ماند.
    // پس در همه‌ی مسیرهای خروج (منو، Apple Event، SIGTERM) آن را برمی‌گردانیم.
    func applicationWillTerminate(_ aNotification: Notification) {
        restoreBeforeExit()
    }

    func restoreBeforeExit() {
        isEnabled = false
        stopMonitoring()
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

    // ---------- اطلاع‌رسانی ----------

    // وقتی برنامه از داخل بانْدل اجرا شود، نوتیفیکیشن‌ها از مسیر UserNotifications
    // فرستاده می‌شوند و آیکن خود برنامه را نشان می‌دهند. مسیر قدیمی osascript
    // نوتیفیکیشن را به نام و آیکن Script Editor نمایش می‌داد.
    // اجرای باینری خام (خارج از .app) بانْدل ندارد و در آن حالت
    // UNUserNotificationCenter.current() برنامه را کرش می‌کند.
    var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func setupNotifications(then completion: @escaping () -> Void) {
        guard isBundled else {
            completion()
            return
        }
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationAuthorization(then: completion)
    }

    // وضعیت مجوز را از سیستم می‌پرسد. اگر کاربر بعداً از تنظیمات سیستم
    // نوتیفیکیشن را روشن کند، بدون ری‌استارت برنامه هم اثر می‌کند.
    func refreshNotificationAuthorization(then completion: (() -> Void)? = nil) {
        guard isBundled else {
            completion?()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    DispatchQueue.main.async {
                        self?.useUserNotifications = granted
                        completion?()
                    }
                }
            case .authorized, .provisional:
                DispatchQueue.main.async {
                    self?.useUserNotifications = true
                    completion?()
                }
            default:
                DispatchQueue.main.async {
                    self?.useUserNotifications = false
                    completion?()
                }
            }
        }
    }

    func sendNotification(title: String, message: String) {
        guard useUserNotifications else {
            sendNotificationViaAppleScript(title: title, message: message)
            // شاید مجوز بعد از اجرا داده شده باشد؛ برای دفعه‌ی بعد دوباره می‌پرسیم
            refreshNotificationAuthorization()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // مسیر جایگزین: بدون بانْدل یا بدون مجوز نوتیفیکیشن
    func sendNotificationViaAppleScript(title: String, message: String) {
        let safeTitle = appleScriptLiteral(title)
        let safeMessage = appleScriptLiteral(message)
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "display notification \(safeMessage) with title \(safeTitle)"]
            try? task.run()
        }
    }

    // نقل‌قول و بک‌اسلش باید escape شوند وگرنه اسکریپت نامعتبر می‌شود
    func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
    func resetFailureState() {
        failureCount = 0
        lastFailureAt = nil
        reportedGivingUp = false
    }

    @objc func reconcile() {
        guard isEnabled, !isSleeping, !isApplying else { return }

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
            resetFailureState()
            // وضعیت فعال/غیرفعال درست است، ولی بک‌لایت ممکن است دوباره روشن شده باشد
            if !desired { enforceZeroBrightness(id) }
            return
        }

        // پس از چند شکست پیاپی، به جای دست کشیدن برای همیشه، یک دوره‌ی
        // خنک‌شدن صبر می‌کنیم و دوباره تلاش می‌کنیم؛ وگرنه برنامه تا رویداد
        // بعدی مانیتورها در حالت غلط گیر می‌کرد و باید دستی ری‌استارت می‌شد.
        if failureCount >= maxFailures {
            guard let last = lastFailureAt, Date().timeIntervalSince(last) >= failureCooldown else {
                if !reportedGivingUp {
                    reportedGivingUp = true
                    sendNotification(title: "Display Toggle Failed",
                                     message: "⚠️ Could not switch the internal display. Retrying shortly.")
                }
                return
            }
            failureCount = 0
        }

        isApplying = true
        let ok = setInternalEnabled(desired)
        isApplying = false

        if ok {
            resetFailureState()
        } else {
            failureCount += 1
            lastFailureAt = Date()
        }
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
            self?.resetFailureState()
            self?.scheduleReconcile(after: 2.0)
        }
    }

    @objc func handleSleep() {
        isSleeping = true
        reconcileWorkItem?.cancel()
        guard isEnabled else { return }
        // قبل از خواب سیستم، مانیتور داخلی را روشن می‌کنیم تا مک‌اواس با حالت عادی بخوابد
        _ = setInternalEnabled(true)
        lastKnownInternalActive = nil
    }

    func handleWake() {
        isSleeping = false
        resetFailureState()
        // شناسه‌ی مانیتور داخلی بعد از بیداری عوض شده؛ کش را دور می‌ریزیم
        internalDisplayID = 0
        lastKnownInternalActive = nil
        resolveInternalDisplay()
        // چند بار در بازه‌های مختلف بررسی می‌کنیم چون مانیتور خارجی ممکن است دیرتر برگردد
        scheduleReconcile(after: 4.0)
    }

    func startMonitoring() {
        // با روشن/خاموش کردن پیاپی، ثبت دوباره‌ی callback تکراری می‌شد
        if !isWatchingDisplays {
            CGDisplayRegisterReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
            isWatchingDisplays = true
        }
        reconcileTimer?.invalidate()

        // تور ایمنی: هر ۵ ثانیه وضعیت واقعی بررسی می‌شود.
        // اگر رویدادی از دست برود یا اعمال تنظیمات شکست بخورد، برنامه خودش را ترمیم می‌کند
        // و دیگر لازم نیست برنامه بسته و دوباره باز شود.
        // با Timer.scheduledTimer تایمر یک بار در مود پیش‌فرض ثبت می‌شد و
        // اضافه‌کردن دوباره‌اش به رون‌لوپ ثبت تکراری بود؛ اینجا فقط یک بار و در
        // مودهای common ثبت می‌شود تا هنگام باز بودن منو هم متوقف نشود.
        let timer = Timer(timeInterval: 5.0, target: self, selector: #selector(reconcile), userInfo: nil, repeats: true)
        timer.tolerance = 2.0
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer

        scheduleReconcile(after: 1.0)
    }

    func stopMonitoring() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        reconcileWorkItem?.cancel()

        if isWatchingDisplays {
            CGDisplayRemoveReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())
            isWatchingDisplays = false
        }
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
        monitor.resetFailureState()
        monitor.scheduleReconcile(after: 2.0)
    }
}

// هندلر رویداد کربن یک تابع C است، پس نباید چیزی را capture کند.
let hotKeyHandler: EventHandlerUPP = { _, event, userInfo in
    guard let event = event, let userInfo = userInfo else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   ByteCount(MemoryLayout<EventHotKeyID>.size),
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return status }

    let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { app.handleHotKey(hotKeyID.id) }
    return noErr
}

// وضعیت «اجرا هنگام ورود» ممکن است از تنظیمات سیستم عوض شده باشد،
// پس هر بار که منو باز می‌شود دوباره خوانده می‌شود.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItemState()
        refreshNotificationAuthorization()
    }
}

// نوتیفیکیشن وقتی برنامه فوکوس دارد به‌صورت پیش‌فرض نمایش داده نمی‌شود
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// ابزار نوار منو: بدون آیکن داک و بدون حضور در Command-Tab
app.setActivationPolicy(.accessory)
app.run()
