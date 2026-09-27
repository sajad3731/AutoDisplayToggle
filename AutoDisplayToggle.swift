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

// MARK: - Menu rows

/// The trailing control of a menu row.
enum MenuRowAccessory: Equatable {
    case none
    /// A switch showing `isOn`. Clicking anywhere in the row flips it.
    case toggle(isOn: Bool)
    /// Right-aligned secondary text, such as a key equivalent.
    case detail(String)
}

/// Everything a row shows. Rows are updated by assigning a new value rather
/// than by reaching into their subviews, so there is exactly one place where
/// state turns into pixels.
struct MenuRowContent: Equatable {
    /// Tried in order; the first symbol this macOS knows is used. A name that
    /// no longer exists costs an icon, never a blank row.
    var symbolNames: [String] = []
    var title: String = ""
    var subtitle: String?
    /// Small trailing text in front of the accessory, e.g. the shortcut that
    /// does the same thing as this row.
    var hint: String?
    var accessory: MenuRowAccessory = .none
    var isDestructive = false
    var isInteractive = true
    var isEnabled = true
}

/// One row of the status menu: an icon, a title, an optional second line, an
/// optional hint and an optional trailing control.
///
/// Every row is one of these, even the ones that are only text. A stock
/// NSMenuItem places its image and title using metrics that cannot be queried,
/// so a menu that mixes stock items with custom views gets a ragged icon
/// column. Drawing every row the same way keeps that column straight by
/// construction.
///
/// A menu item that carries a view gets neither drawing nor action handling
/// from AppKit: the view draws its own highlight and turns clicks into
/// `onClick`. That is what lets a switch flip in place instead of dismissing
/// the menu on every click — and it also means a row that should close the menu
/// has to say so itself.
final class MenuRowView: NSView {

    enum Style {
        case single
        case twoLine

        var height: CGFloat {
            switch self {
            case .single: return 28
            case .twoLine: return 44
            }
        }
    }

    var onClick: (() -> Void)?

    var content = MenuRowContent() {
        didSet {
            guard content != oldValue else { return }
            applyContent()
        }
    }

    private let style: Style
    private let iconView = NSImageView()
    private let titleField = MenuRowView.makeLabel(font: NSFont.menuFont(ofSize: 0))
    private let subtitleField = MenuRowView.makeLabel(font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize))
    private let hintField = MenuRowView.makeLabel(font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize))
    private let detailField = MenuRowView.makeLabel(font: NSFont.menuFont(ofSize: 0))
    private let toggle = NSSwitch()

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }
    private var rowTrackingArea: NSTrackingArea?

    private let leadingInset: CGFloat = 14
    private let trailingInset: CGFloat = 14
    private let iconWidth: CGFloat = 16
    private let iconTitleGap: CGFloat = 10
    private let titleAccessoryGap: CGFloat = 16
    private let hintAccessoryGap: CGFloat = 8

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: style.height))

        detailField.alignment = .right
        hintField.alignment = .right
        iconView.imageScaling = .scaleProportionallyUpOrDown

        // The row handles clicks for its whole width (see hitTest), so the
        // switch is only ever a picture of the state.
        toggle.controlSize = .small
        toggle.refusesFirstResponder = true

        for view in [iconView, titleField, subtitleField, hintField, detailField, toggle] as [NSView] {
            addSubview(view)
        }

        setAccessibilityElement(true)
        applyContent()
    }

    required init?(coder: NSCoder) {
        fatalError("MenuRowView is only built in code")
    }

    // Top-down coordinates keep the two-line layout readable.
    override var isFlipped: Bool { true }

    static func makeLabel(font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        // The row speaks for itself; its labels should not be read separately.
        field.setAccessibilityElement(false)
        return field
    }

    /// The first of `names` that exists on this macOS.
    static func symbolImage(_ names: [String], description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }
        return nil
    }

    // ---------- Content ----------

    private func applyContent() {
        iconView.image = MenuRowView.symbolImage(content.symbolNames, description: content.title)
        titleField.stringValue = content.title

        subtitleField.stringValue = content.subtitle ?? ""
        subtitleField.isHidden = style == .single || subtitleField.stringValue.isEmpty

        hintField.stringValue = content.hint ?? ""
        hintField.isHidden = hintField.stringValue.isEmpty

        switch content.accessory {
        case .none:
            toggle.isHidden = true
            detailField.isHidden = true
        case .toggle(let isOn):
            toggle.isHidden = false
            toggle.state = isOn ? .on : .off
            detailField.isHidden = true
        case .detail(let text):
            toggle.isHidden = true
            detailField.isHidden = false
            detailField.stringValue = text
        }

        toggle.isEnabled = content.isEnabled
        applyAccessibility()
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    private func applyAccessibility() {
        if case .toggle(let isOn) = content.accessory {
            setAccessibilityRole(.checkBox)
            setAccessibilityValue(isOn)
        } else {
            setAccessibilityRole(content.isInteractive ? .button : .staticText)
            setAccessibilityValue(nil)
        }
        setAccessibilityLabel([content.title, content.subtitle]
            .compactMap { $0 }
            .joined(separator: ", "))
    }

    private var showsHighlight: Bool {
        isHovered && content.isInteractive && content.isEnabled
    }

    private func applyColors() {
        let primary: NSColor
        if showsHighlight {
            primary = .selectedMenuItemTextColor
        } else if !content.isEnabled {
            primary = .disabledControlTextColor
        } else if content.isDestructive {
            primary = .systemRed
        } else {
            primary = .labelColor
        }

        // A red title on the accent-coloured highlight is the reason the row
        // draws its own colours instead of using an attributed title.
        let secondary: NSColor = showsHighlight
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor

        titleField.textColor = primary
        subtitleField.textColor = secondary
        detailField.textColor = secondary
        hintField.textColor = showsHighlight ? secondary : NSColor.tertiaryLabelColor
        iconView.contentTintColor = showsHighlight ? NSColor.selectedMenuItemTextColor : primary
    }

    /// Clears the highlight for a menu that closed with the cursor on this row,
    /// which never produces a mouseExited.
    func resetHover() {
        isHovered = false
    }

    // ---------- Layout ----------

    private var toggleSize: NSSize {
        let size = toggle.intrinsicContentSize
        guard size.width > 1, size.height > 1 else { return NSSize(width: 38, height: 22) }
        return size
    }

    /// Width this row needs for its content, so the menu can give every row the
    /// same one.
    var contentWidth: CGFloat {
        var width = leadingInset + iconWidth + iconTitleGap

        var textWidth = titleField.fittingSize.width
        if !subtitleField.isHidden {
            textWidth = max(textWidth, subtitleField.fittingSize.width)
        }
        width += textWidth

        if !hintField.isHidden {
            width += hintAccessoryGap + hintField.fittingSize.width
        }

        switch content.accessory {
        case .none:
            break
        case .toggle:
            width += titleAccessoryGap + toggleSize.width
        case .detail:
            width += titleAccessoryGap + detailField.fittingSize.width
        }

        return ceil(width + trailingInset)
    }

    override func layout() {
        super.layout()

        iconView.frame = NSRect(x: leadingInset,
                                y: ((bounds.height - iconWidth) / 2).rounded(),
                                width: iconWidth,
                                height: iconWidth)

        var textRight = bounds.width - trailingInset

        switch content.accessory {
        case .none:
            break
        case .toggle:
            let size = toggleSize
            toggle.frame = NSRect(x: textRight - size.width,
                                  y: ((bounds.height - size.height) / 2).rounded(),
                                  width: size.width,
                                  height: size.height)
            textRight -= size.width + titleAccessoryGap
        case .detail:
            let size = detailField.fittingSize
            detailField.frame = NSRect(x: textRight - size.width,
                                       y: ((bounds.height - size.height) / 2).rounded(),
                                       width: size.width,
                                       height: size.height)
            textRight -= size.width + titleAccessoryGap
        }

        if !hintField.isHidden {
            let size = hintField.fittingSize
            hintField.frame = NSRect(x: textRight - size.width,
                                     y: ((bounds.height - size.height) / 2).rounded(),
                                     width: size.width,
                                     height: size.height)
            textRight -= size.width + hintAccessoryGap
        }

        let textLeft = leadingInset + iconWidth + iconTitleGap
        let textWidth = max(textRight - textLeft, 0)

        if subtitleField.isHidden {
            let height = titleField.fittingSize.height
            titleField.frame = NSRect(x: textLeft,
                                      y: ((bounds.height - height) / 2).rounded(),
                                      width: textWidth,
                                      height: height)
        } else {
            let titleHeight = titleField.fittingSize.height
            let subtitleHeight = subtitleField.fittingSize.height
            let top = ((bounds.height - (titleHeight + 2 + subtitleHeight)) / 2).rounded()
            titleField.frame = NSRect(x: textLeft, y: top, width: textWidth, height: titleHeight)
            subtitleField.frame = NSRect(x: textLeft,
                                         y: top + titleHeight + 2,
                                         width: textWidth,
                                         height: subtitleHeight)
        }
    }

    // ---------- Highlight and clicks ----------

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsHighlight else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = rowTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        rowTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    /// A menu routes events to the deepest view it hits. Claiming the whole row
    /// keeps the decision about what a click does in one place, and spares the
    /// switch from having to track the mouse inside the menu's own event loop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview = superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard content.isInteractive, content.isEnabled else { return }
        // Menu tracking does not reliably deliver mouseUp to an item's view,
        // so the press is what counts.
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard content.isInteractive, content.isEnabled else { return false }
        onClick?()
        return true
    }
}

// MARK: - Menu state

enum LoginItemState: Equatable {
    case on
    case off
    case needsApproval
}

/// What one pass over the display list found.
struct DisplaySurvey {
    var internalPresent = false
    var internalActive = false
    var externalActiveCount = 0
}

/// Everything the menu shows, resolved in one go. Rendering from a single
/// snapshot is what keeps the menu bar icon, the header and the switch from
/// contradicting each other.
struct MenuState: Equatable {
    var isEnabled: Bool
    var internalDisplayPresent: Bool
    var internalDisplayActive: Bool
    var externalDisplayCount: Int
    var loginItem: LoginItemState
    var hotKeysRegistered: Bool

    var headerTitle: String {
        guard internalDisplayPresent else { return "Built-in display not detected" }
        return internalDisplayActive ? "Internal display is on" : "Internal display is off"
    }

    var headerSubtitle: String {
        // In clamshell mode the built-in panel is not enumerated at all, so
        // there is nothing for the app to switch.
        guard internalDisplayPresent else { return "Nothing to switch, the lid may be closed" }

        switch externalDisplayCount {
        case 0: return "No external display connected"
        case 1: return "1 external display connected"
        default: return "\(externalDisplayCount) external displays connected"
        }
    }

    var headerSymbolNames: [String] {
        guard internalDisplayPresent else {
            return ["display.trianglebadge.exclamationmark", "exclamationmark.triangle", "display"]
        }
        return internalDisplayActive ? ["display.2", "display"] : ["display"]
    }

    /// Three states, so the menu bar tells "idle" and "internal panel dark"
    /// apart instead of showing the same icon for both.
    var statusSymbolNames: [String] {
        guard isEnabled else { return ["display"] }
        if internalDisplayActive || !internalDisplayPresent { return ["display.2", "display"] }
        return ["display"]
    }

    /// The shortcut for what the switch is about to do. Left out when the hot
    /// keys could not be claimed, since printing a shortcut another app owns is
    /// worse than printing none.
    var switchingShortcutHint: String? {
        guard hotKeysRegistered else { return nil }
        return isEnabled ? "⌃⌥⌘D" : "⌃⌥⌘E"
    }

    /// macOS keeps the registration but waits for the user to allow it, and the
    /// only thing the app can do about that is point at the right settings pane.
    var loginApprovalHint: String? {
        loginItem == .needsApproval ? "Approve…" : nil
    }
}

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

    var statusRow: MenuRowView!
    var switchingRow: MenuRowView!
    var loginRow: MenuRowView!
    var menuRows: [MenuRowView] = []
    var renderedMenuState: MenuState?
    var menuRefreshTimer: Timer?
    // The hot keys are claimed after the menu is built, so the menu only
    // advertises a shortcut once it is really ours.
    var hotKeysRegistered = true

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

    // ---------- Menu ----------

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // Every row is a custom view, so there is nothing for AppKit's own
        // drawing and auto-enabling to act on; the views decide how they look.
        menu.autoenablesItems = false
        menu.delegate = self

        statusRow = MenuRowView(style: .twoLine)
        let statusRowItem = rowItem(statusRow, accessibilityTitle: "Status")
        // Nothing to activate here, so arrow keys skip it.
        statusRowItem.isEnabled = false
        menu.addItem(statusRowItem)
        menu.addItem(NSMenuItem.separator())

        switchingRow = MenuRowView(style: .single)
        switchingRow.onClick = { [weak self] in self?.toggleEnabled() }
        menu.addItem(rowItem(switchingRow, accessibilityTitle: "Automatic switching"))

        loginRow = MenuRowView(style: .single)
        loginRow.onClick = { [weak self] in self?.toggleLoginItem() }
        menu.addItem(rowItem(loginRow, accessibilityTitle: "Start at Login"))
        menu.addItem(NSMenuItem.separator())

        // This row used to carry a ⌘R key equivalent, which reconfigured the
        // displays on a mistyped shortcut while the menu was open. It is a
        // deliberate action, so it now takes a deliberate click.
        let panicRow = MenuRowView(style: .single)
        panicRow.content = MenuRowContent(symbolNames: ["arrow.counterclockwise"],
                                          title: "Reset Displays (Panic)",
                                          isDestructive: true)
        panicRow.onClick = { [weak self] in
            // A row with a view has to dismiss the menu itself.
            self?.statusItem.menu?.cancelTracking()
            self?.manualReset()
        }
        menu.addItem(rowItem(panicRow, accessibilityTitle: "Reset Displays (Panic)"))

        let quitRow = MenuRowView(style: .single)
        quitRow.content = MenuRowContent(symbolNames: ["xmark.circle"],
                                         title: "Quit AutoDisplayToggle",
                                         accessory: .detail("⌘Q"))
        quitRow.onClick = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            self?.quitApp()
        }
        let quitItem = rowItem(quitRow, accessibilityTitle: "Quit AutoDisplayToggle")
        // A view takes over drawing and clicks, but key equivalents stay with
        // the menu, so Quit keeps ⌘Q while the menu is open.
        quitItem.keyEquivalent = "q"
        quitItem.target = self
        quitItem.action = #selector(quitApp)
        menu.addItem(quitItem)

        statusItem.menu = menu
        menuRows = [statusRow, switchingRow, loginRow, panicRow, quitRow]
        refreshMenu()
    }

    func rowItem(_ view: MenuRowView, accessibilityTitle: String) -> NSMenuItem {
        let item = NSMenuItem()
        // The title never draws once a view is attached, but VoiceOver and the
        // menu's own bookkeeping still read it.
        item.title = accessibilityTitle
        item.view = view
        return item
    }

    // ---------- Rendering ----------

    /// Reads the current state once and hands it to the rows. Skipping the
    /// render when nothing changed keeps this cheap enough to call from the
    /// reconcile loop and from a timer while the menu is open.
    @objc func refreshMenu() {
        guard statusItem != nil else { return }

        let state = currentMenuState()
        guard state != renderedMenuState else { return }
        renderedMenuState = state
        render(state)
    }

    func currentMenuState() -> MenuState {
        let survey = surveyDisplays()
        return MenuState(isEnabled: isEnabled,
                         internalDisplayPresent: survey.internalPresent,
                         internalDisplayActive: survey.internalActive,
                         externalDisplayCount: survey.externalActiveCount,
                         loginItem: currentLoginItemState(),
                         hotKeysRegistered: hotKeysRegistered)
    }

    /// One pass over the display list for everything the menu reports. The
    /// reconcile loop keeps its own reads, which answer a narrower question.
    func surveyDisplays() -> DisplaySurvey {
        var survey = DisplaySurvey()
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &displays, &displayCount) == .success else { return survey }

        for i in 0..<Int(displayCount) {
            let id = displays[i]
            if CGDisplayIsBuiltin(id) != 0 {
                survey.internalPresent = true
                survey.internalActive = CGDisplayIsActive(id) != 0
            } else if CGDisplayIsActive(id) != 0 {
                survey.externalActiveCount += 1
            }
        }
        return survey
    }

    func render(_ state: MenuState) {
        renderStatusButton(state)

        statusRow.content = MenuRowContent(symbolNames: state.headerSymbolNames,
                                           title: state.headerTitle,
                                           subtitle: state.headerSubtitle,
                                           isInteractive: false)

        switchingRow.content = MenuRowContent(symbolNames: [state.isEnabled ? "bolt.fill" : "bolt.slash"],
                                              title: "Automatic switching",
                                              hint: state.switchingShortcutHint,
                                              accessory: .toggle(isOn: state.isEnabled))

        loginRow.content = MenuRowContent(symbolNames: ["power"],
                                          title: "Start at Login",
                                          hint: state.loginApprovalHint,
                                          accessory: .toggle(isOn: state.loginItem == .on))

        normalizeRowWidths()
    }

    func renderStatusButton(_ state: MenuState) {
        guard let button = statusItem.button else { return }

        let description = "AutoDisplayToggle: \(state.headerTitle.lowercased())"
        // Never clear the image: an unknown symbol name would leave an
        // invisible, unclickable status item.
        if let image = MenuRowView.symbolImage(state.statusSymbolNames, description: description) {
            button.image = image
        }
        // Dimming the icon keeps an idle app recognisable from the menu bar
        // alone, and unlike disabling it, the menu still opens.
        button.alphaValue = state.isEnabled ? 1.0 : 0.55
        button.toolTip = state.isEnabled
            ? "\(state.headerTitle)\n\(state.headerSubtitle)"
            : "Automatic switching is off\n\(state.headerSubtitle)"
    }

    /// A menu is as wide as its widest item view, and each row draws its own
    /// highlight, so a row that kept a narrower width would highlight short of
    /// the others.
    func normalizeRowWidths() {
        let width = max(menuRows.map { $0.contentWidth }.max() ?? 0, 240)
        for row in menuRows where abs(row.frame.width - width) > 0.5 {
            row.setFrameSize(NSSize(width: width, height: row.frame.height))
            row.needsLayout = true
        }
    }

    func startMenuRefreshTimer() {
        stopMenuRefreshTimer()
        // Menu tracking runs its own run loop mode, so a timer registered only
        // in the default mode stops ticking the moment the menu opens.
        let timer = Timer(timeInterval: 1.0,
                          target: self,
                          selector: #selector(refreshMenu),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func stopMenuRefreshTimer() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    // ---------- Start at Login ----------

    func currentLoginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    @objc func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                sendNotification(title: "Start at Login",
                                 message: "⛔️ AutoDisplayToggle will no longer start automatically.")
            case .requiresApproval:
                // The registration stands; only the user can approve it.
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                sendNotification(title: "Start at Login",
                                 message: "✅ AutoDisplayToggle will start automatically at login.")
            }
        } catch {
            sendNotification(title: "Start at Login Failed", message: "⚠️ \(error.localizedDescription)")
        }

        refreshMenu()
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
        refreshMenu()

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

        hotKeysRegistered = offRegistered && onRegistered
        // The menu was built before the hot keys were claimed, so let it drop
        // the shortcut hint when they are not ours.
        refreshMenu()

        if !hotKeysRegistered {
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
        // Whatever this pass decides, the menu ends up describing it.
        defer { refreshMenu() }
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
                                   // نوع این پارامتر (ByteCount) در سوییفت نامی
                                   // ندارد، پس با .init از روی خود پارامتر ساخته می‌شود
                                   .init(MemoryLayout<EventHotKeyID>.size),
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return status }

    let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { app.handleHotKey(hotKeyID.id) }
    return noErr
}

// The header and the switches describe live system state, and a menu does not
// redraw itself while it sits open, so it gets its own tick for as long as it
// is on screen. Start at Login can also be changed from System Settings behind
// the app's back, and the same refresh picks that up.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        refreshNotificationAuthorization()
        startMenuRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMenuRefreshTimer()
        // A row the cursor was on when the menu closed never sees mouseExited,
        // so it would come back highlighted.
        for row in menuRows { row.resetHover() }
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
