import Cocoa
import CoreGraphics
import UserNotifications
import ServiceManagement
import IOKit.graphics
import IOKit.ps
import Carbon.HIToolbox // برای میانبرهای سراسری
import os

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

// این توابع در سمت C مقدار ۳۲ بیتی برمی‌گردانند؛ اگر Int (۶۴ بیتی) اعلام شوند
// بیت‌های بالایی نامعتبرند و مقایسه‌ی نتیجه با صفر غیرقابل‌اتکا می‌شود.
@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

// The full display mode list, HiDPI sizes included, and the call that sets
// one by index. See ScaleMode. All return a CGError as a raw 32-bit value.
@_silgen_name("CGSGetNumberOfDisplayModes")
func CGSGetNumberOfDisplayModes(_ display: CGDirectDisplayID, _ count: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
func CGSGetDisplayModeDescriptionOfLength(_ display: CGDirectDisplayID, _ index: Int32,
                                          _ description: UnsafeMutableRawPointer, _ length: Int32) -> Int32

@_silgen_name("CGSGetCurrentDisplayMode")
func CGSGetCurrentDisplayMode(_ display: CGDirectDisplayID, _ index: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSConfigureDisplayMode")
func CGSConfigureDisplayMode(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ index: Int32) -> Int32

/// The few settings that outlive a launch. A pause is deliberately not one of
/// them: coming back from a reboot with switching silently off would look like
/// a broken app.
enum Preference {
    static let notificationsEnabled = "NotificationsEnabled"
    static let restoreBrightness = "RestoreBrightness"
    static let preferHighestRefreshRate = "PreferHighestRefreshRate"
    /// Rates the user kept or turned down, per monitor and resolution.
    static let trustedRefreshRates = "TrustedRefreshRates"
    static let rejectedRefreshRates = "RejectedRefreshRates"
    /// A rate picked by hand, per monitor. It wins over "Always use highest
    /// rate", and is put back whenever the monitor comes back at another one.
    static let pinnedRefreshRates = "PinnedRefreshRates"
    /// System sleep off while an external display is connected, so the lid
    /// can close on battery too.
    static let stayAwakeLidClosed = "StayAwakeWithLidClosed"
    /// Every display at a size that makes the interface look equally big.
    static let matchUISize = "MatchUISize"
    /// The user's offset from that size, in UISize steps.
    static let uiSizeStep = "UISizeStep"
    /// Sizes picked by hand in System Settings, per monitor, which matching
    /// leaves alone until the switch or the slider is touched again.
    static let uiSizeManual = "UISizeManual"
    /// Set while the app runs and cleared on a clean exit, so a launch can
    /// tell that the run before it crashed or was killed.
    static let sessionOpen = "LogSessionOpen"
}

// MARK: - Log

/// Errors and the events around them, kept on this Mac only, in two places:
///
/// - The unified log, under the bundle identifier as subsystem, for Console.app
///   and `log show`.
/// - A JSON Lines file in ~/Library/Logs/AutoDisplayToggle, one object per
///   line, which survives reboots and can be read back without any tool.
///
/// Writes go through one serial queue, so callers never wait on the disk.
/// The file is rotated at `maxFileBytes`, keeping one older generation.
enum Log {
    enum Level: String {
        case info, warning, error

        var osLogType: OSLogType {
            switch self {
            case .info: return .default
            case .warning: return .error
            case .error: return .fault
            }
        }
    }

    enum Category: String {
        case lifecycle, display, brightness, mirroring, refreshRate, uiSize
        case override, sleep, desktop, login, hotKey, notification, user
    }

    static let subsystem = Bundle.main.bundleIdentifier ?? "AutoDisplayToggle"
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AutoDisplayToggle", isDirectory: true)
    static let file = directory.appendingPathComponent("events.jsonl")
    static let previousFile = directory.appendingPathComponent("events.1.jsonl")
    static let maxFileBytes: UInt64 = 2_000_000

    private static let queue = DispatchQueue(label: "AutoDisplayToggle.log", qos: .utility)
    // Touched only on `queue`.
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var throttled: [String: (last: Date, suppressed: Int)] = [:]

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func info(_ category: Category, _ message: String, _ fields: [String: Any] = [:],
                     throttle: TimeInterval? = nil) {
        write(.info, category, message, fields, throttle: throttle)
    }

    static func warning(_ category: Category, _ message: String, _ fields: [String: Any] = [:],
                        throttle: TimeInterval? = nil) {
        write(.warning, category, message, fields, throttle: throttle)
    }

    static func error(_ category: Category, _ message: String, _ fields: [String: Any] = [:],
                      throttle: TimeInterval? = nil) {
        write(.error, category, message, fields, throttle: throttle)
    }

    /// `throttle` keeps a message that repeats on a timer from flooding the
    /// log: within the window, repeats are only counted, and the next one
    /// written after it carries that count as `repeats`.
    static func write(_ level: Level, _ category: Category, _ message: String, _ fields: [String: Any],
                      throttle: TimeInterval?) {
        let now = Date()
        queue.async {
            var fields = fields
            if let window = throttle {
                let key = "\(category.rawValue)|\(message)"
                if let entry = throttled[key], now.timeIntervalSince(entry.last) < window {
                    throttled[key] = (entry.last, entry.suppressed + 1)
                    return
                }
                if let suppressed = throttled[key]?.suppressed, suppressed > 0 { fields["repeats"] = suppressed }
                throttled[key] = (now, 0)
            }

            let detail = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
            let text = detail.isEmpty ? message : "\(message) \(detail)"
            Logger(subsystem: subsystem, category: category.rawValue)
                .log(level: level.osLogType, "\(text, privacy: .public)")

            var record: [String: Any] = ["ts": timestamp.string(from: now),
                                         "level": level.rawValue,
                                         "cat": category.rawValue,
                                         "msg": message]
            if !fields.isEmpty { record["fields"] = jsonSafe(fields) }
            guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            append(line)
        }
    }

    /// Waits for every queued write. Called before the process exits.
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func jsonSafe(_ fields: [String: Any]) -> [String: Any] {
        fields.mapValues { value in
            switch value {
            case let value as Bool: return value
            case let value as Int: return value
            case let value as Int32: return Int(value)
            case let value as UInt32: return Int(value)
            case let value as Double: return value.isFinite ? value : String(describing: value)
            case let value as Float: return value.isFinite ? Double(value) : String(describing: value)
            case let value as String: return value
            case let value as [String]: return value
            case let value as [Int]: return value
            default: return String(describing: value)
            }
        }
    }

    private static func append(_ line: Data) {
        if handle == nil { open() }
        guard let handle = handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            if try handle.offset() > maxFileBytes { rotate() }
        } catch {
            // The unified log copy still went out; drop the handle and reopen
            // on the next line, in case the file was deleted underneath.
            try? handle.close()
            self.handle = nil
        }
    }

    private static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previousFile)
        try? fm.moveItem(at: file, to: previousFile)
        open()
    }

    /// One line describing the machine and the run, so every later line can
    /// be read against it.
    static func launch() {
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        var model = [CChar](repeating: 0, count: 256)
        var size = model.count
        let hasModel = sysctlbyname("hw.model", &model, &size, nil, 0) == 0
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        info(.lifecycle, "launched", [
            "version": bundleInfo["CFBundleShortVersionString"] as? String ?? "unbundled",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": hasModel ? String(cString: model) : "unknown",
            "arch": arch,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ])

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Preference.sessionOpen) {
            warning(.lifecycle, "previous run did not exit cleanly (crash, force quit or power loss)")
        }
        defaults.set(true, forKey: Preference.sessionOpen)
        reportCrashes()
    }

    static func exited(_ reason: String) {
        info(.lifecycle, "exiting", ["reason": reason])
        UserDefaults.standard.set(false, forKey: Preference.sessionOpen)
        flush()
    }

    /// macOS keeps its own crash reports. Any new since the last launch are
    /// pointed to from the log, since a crash can't write anything itself.
    private static func reportCrashes() {
        let key = "LogLastCrashScan"
        let defaults = UserDefaults.standard
        let since = defaults.object(forKey: key) as? Date ?? .distantPast
        defaults.set(Date(), forKey: key)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let reports = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in reports where url.lastPathComponent.hasPrefix("AutoDisplayToggle") {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > since else { continue }
            error(.lifecycle, "crash report found", ["path": url.path, "date": timestamp.string(from: modified)])
        }
    }
}

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
    /// A slider on a line of its own, with its value shown as a percentage.
    case slider(value: Double)
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
    /// Shown beside a slider instead of its value as a percentage.
    var sliderLabel: String?
    var isDestructive = false
    var isInteractive = true
    var isEnabled = true
}

/// The switch drawn in a menu row.
///
/// A menu's window never becomes key, so NSSwitch always draws its inactive
/// look there: a grey track whether it is on or off, with only the side of the
/// knob telling the two apart. This one fills with the accent colour when on,
/// the way switches look in a focused window and in Control Center.
///
/// It is only a picture of the state; the row handles clicks for it.
final class MenuSwitchView: NSView {

    private(set) var isOn = false
    var isEnabled = true {
        didSet { if isEnabled != oldValue { updateLayers(animated: false) } }
    }
    /// The row is showing its selection highlight, which is itself accent
    /// coloured, so an accent track on top of it would disappear.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { updateLayers(animated: false) } }
    }

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    /// macOS 26 draws switches with a wider track and a capsule knob.
    private static var usesCapsuleKnob: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var trackSize: NSSize {
        usesCapsuleKnob ? NSSize(width: 36, height: 20) : NSSize(width: 32, height: 18)
    }

    private static let knobInset: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(knobLayer)

        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.22
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)

        setAccessibilityElement(false)

        // The accent colour can change while the app runs.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(systemColorsChanged),
                                               name: NSColor.systemColorsDidChangeNotification,
                                               object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("MenuSwitchView is only built in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize { MenuSwitchView.trackSize }
    override var wantsUpdateLayer: Bool { true }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        updateLayers(animated: animated && window != nil && !isHidden)
    }

    override func updateLayer() {
        updateLayers(animated: false)
    }

    override func layout() {
        super.layout()
        updateLayers(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers(animated: false)
    }

    @objc private func systemColorsChanged() {
        updateLayers(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Dynamic colours only resolve against an appearance at the moment they
    /// are read, and layers keep a fixed CGColor.
    private func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        return cgColor
    }

    private func updateLayers(animated: Bool) {
        let size = MenuSwitchView.trackSize
        let inset = MenuSwitchView.knobInset
        let knobHeight = size.height - inset * 2
        let knobWidth = MenuSwitchView.usesCapsuleKnob ? (knobHeight * 1.4).rounded() : knobHeight

        let trackColor: NSColor
        let knobColor: NSColor
        switch (isOn, isHighlighted) {
        case (true, false):
            trackColor = .controlAccentColor
            knobColor = .white
        case (true, true):
            trackColor = .selectedMenuItemTextColor
            knobColor = .controlAccentColor
        case (false, false):
            trackColor = NSColor.labelColor.withAlphaComponent(0.16)
            knobColor = .white
        case (false, true):
            trackColor = NSColor.selectedMenuItemTextColor.withAlphaComponent(0.35)
            knobColor = .selectedMenuItemTextColor
        }

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        trackLayer.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                                  y: ((bounds.height - size.height) / 2).rounded(),
                                  width: size.width,
                                  height: size.height)
        trackLayer.cornerRadius = size.height / 2
        trackLayer.backgroundColor = resolved(trackColor)

        let knobX = isOn ? size.width - inset - knobWidth : inset
        knobLayer.frame = CGRect(x: knobX, y: inset, width: knobWidth, height: knobHeight)
        knobLayer.cornerRadius = knobHeight / 2
        knobLayer.backgroundColor = resolved(knobColor)
        knobLayer.shadowOpacity = isHighlighted ? 0 : 0.22

        layer?.opacity = isEnabled ? 1 : 0.4

        CATransaction.commit()
    }
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
        case slider

        var height: CGFloat {
            switch self {
            case .single: return 28
            case .twoLine: return 44
            case .slider: return 48
            }
        }
    }

    var onClick: (() -> Void)?
    var onSliderChange: ((Double) -> Void)?

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
    private let toggle = MenuSwitchView()
    private let slider = NSSlider()

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

        // The slider is the one control that has to track the mouse itself, so
        // it keeps its own target and hitTest lets events through to it.
        slider.controlSize = .small
        // Like NSSwitch, a slider in a menu draws its inactive grey fill.
        slider.trackFillColor = .controlAccentColor
        slider.minValue = 0.05
        slider.maxValue = 1.0
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        slider.target = self
        slider.action = #selector(sliderMoved)

        for view in [iconView, titleField, subtitleField, hintField, detailField, toggle, slider] as [NSView] {
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
            slider.isHidden = true
            detailField.isHidden = true
        case .toggle(let isOn):
            // Slide the knob only when the switch was already on screen;
            // a row that just turned into a switch shows its state at once.
            toggle.setOn(isOn, animated: !toggle.isHidden)
            toggle.isHidden = false
            slider.isHidden = true
            detailField.isHidden = true
        case .detail(let text):
            toggle.isHidden = true
            slider.isHidden = true
            detailField.isHidden = false
            detailField.stringValue = text
        case .slider(let value):
            toggle.isHidden = true
            slider.isHidden = false
            detailField.isHidden = false
            detailField.stringValue = content.sliderLabel ?? "\(Int((value * 100).rounded()))%"
            // Never write back the value a drag is already showing, or the knob
            // fights the cursor.
            if abs(slider.doubleValue - value) > 0.005 {
                slider.doubleValue = value
            }
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
        toggle.isHighlighted = showsHighlight
    }

    /// Makes the slider snap to `count` evenly spaced stops across its range.
    func setSliderStops(_ count: Int) {
        slider.numberOfTickMarks = count
        slider.allowsTickMarkValuesOnly = true
    }

    /// Clears the highlight for a menu that closed with the cursor on this row,
    /// which never produces a mouseExited.
    func resetHover() {
        isHovered = false
    }

    // ---------- Layout ----------

    private var toggleSize: NSSize { MenuSwitchView.trackSize }

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
        case .slider:
            // The first line holds the title and the percentage; the slider has
            // the second line to itself and only needs room to be draggable.
            return ceil(max(width + titleAccessoryGap + detailField.fittingSize.width + trailingInset, 260))
        }

        return ceil(width + trailingInset)
    }

    override func layout() {
        super.layout()

        if case .slider = content.accessory {
            layoutSliderRow()
            return
        }

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
        case .slider:
            break // laid out by layoutSliderRow()
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

    /// Title and value on the first line, slider across the second. A slider
    /// squeezed in beside a label is too small to aim at.
    private func layoutSliderRow() {
        let lineHeight: CGFloat = 18
        let topInset: CGFloat = 5
        let textLeft = leadingInset + iconWidth + iconTitleGap

        iconView.frame = NSRect(x: leadingInset,
                                y: topInset + ((lineHeight - iconWidth) / 2).rounded(),
                                width: iconWidth,
                                height: iconWidth)

        let detailSize = detailField.fittingSize
        detailField.frame = NSRect(x: bounds.width - trailingInset - detailSize.width,
                                   y: topInset + ((lineHeight - detailSize.height) / 2).rounded(),
                                   width: detailSize.width,
                                   height: detailSize.height)

        let titleHeight = titleField.fittingSize.height
        titleField.frame = NSRect(x: textLeft,
                                  y: topInset + ((lineHeight - titleHeight) / 2).rounded(),
                                  width: max(detailField.frame.minX - 8 - textLeft, 0),
                                  height: titleHeight)

        let sliderHeight: CGFloat = 16
        slider.frame = NSRect(x: textLeft,
                              y: bounds.height - sliderHeight - 8,
                              width: max(bounds.width - trailingInset - textLeft, 0),
                              height: sliderHeight)
    }

    // ---------- Highlight and clicks ----------

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsHighlight else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        // macOS 26 menus have rounder corners, and the highlight follows them
        // so it sits concentric inside the menu.
        let radius: CGFloat
        if #available(macOS 26.0, *) {
            radius = 8
        } else {
            radius = 5
        }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: radius, yRadius: radius).fill()
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
        // A slider is the exception: it has to receive the drag itself.
        if case .slider = content.accessory { return super.hitTest(point) }
        guard let superview = superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard content.isInteractive, content.isEnabled else { return }
        // Menu tracking does not reliably deliver mouseUp to an item's view,
        // so the press is what counts.
        onClick?()
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        onSliderChange?(sender.doubleValue)
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

/// One display, as the menu lists it.
struct DisplayInfo: Equatable {
    var id: CGDirectDisplayID
    var isBuiltin: Bool
    var isActive: Bool
    /// In a mirror set. Only the primary of a hardware mirror set counts as
    /// active, yet the others still light up and still cost a composite.
    var isMirrored: Bool
    var name: String

    /// Showing a picture, mirrored or not.
    var isShowing: Bool { isActive || isMirrored }
}

/// The refresh rates an external display offers at the resolution it is
/// running now. Changing resolution is System Settings' job; this only moves
/// along the rate axis, so the desktop never changes size under the user.
struct RefreshRateInfo: Equatable {
    var displayID: CGDirectDisplayID
    var name: String
    var currentHz: Double
    /// Highest first, one entry per whole-number rate.
    var availableHz: [Double]
    /// The display's identity plus the pixel size it runs at. A verdict on a
    /// rate is only worth remembering for this monitor at this resolution.
    var verdictKeyPrefix: String
    /// Vendor, product and serial, which outlive a reconnect or a reboot where
    /// the CGDirectDisplayID does not.
    var displayKey: String
    /// The rate the user picked by hand for this monitor, if any.
    var pinnedHz: Int?
    var isNativeResolution: Bool
    var nativeSizeLabel: String?
    /// A standard rate the EDID's own limits allow at the native resolution
    /// that macOS does not list, and that an override could add.
    var unlockCandidateHz: Int?
    /// Native rates the display override adds on top of the monitor's EDID.
    var unlockedHz: [Int]
    /// Unlocked, but macOS has not picked them up yet: that happens when the
    /// display is connected, so it needs a replug or a restart.
    var pendingHz: [Int]
    var trustedHz: Set<Int>
    var rejectedHz: Set<Int>

    var currentLabel: Int { RefreshRateInfo.label(currentHz) }
    var highestHz: Double? { availableHz.first }

    /// What "Always use highest rate" aims for: the best rate on offer that the
    /// user has not turned down on this monitor.
    var autoTargetHz: Int? {
        availableHz.map(RefreshRateInfo.label).first { !rejectedHz.contains($0) }
    }

    var availableLabels: [Int] { availableHz.map(RefreshRateInfo.label) }

    /// The pinned rate when this resolution offers it. A pin for a rate the
    /// current resolution lacks is kept, but does nothing until it applies.
    var effectivePinHz: Int? {
        guard let pinned = pinnedHz, availableLabels.contains(pinned) else { return nil }
        return pinned
    }

    /// What this monitor should run at, or nil to leave it alone: a pin always
    /// wins, so a rate the panel skips frames at is never forced back on.
    func targetHz(preferHighest: Bool) -> Int? {
        effectivePinHz ?? (preferHighest ? autoTargetHz : nil)
    }

    /// The monitor never claimed this rate itself, so it is only switched to
    /// silently once somebody has seen it work.
    func needsTrial(_ hz: Int) -> Bool {
        isNativeResolution && unlockedHz.contains(hz) && !trustedHz.contains(hz)
    }

    /// A rate picked by hand switches at once when the monitor claims it, or
    /// when it was kept before. An untested unlock, or one that was reverted,
    /// goes through keep-or-revert.
    func needsConfirmation(_ hz: Int) -> Bool {
        needsTrial(hz) || rejectedHz.contains(hz)
    }

    func verdictKey(_ hz: Int) -> String { "\(verdictKeyPrefix)@\(hz)" }

    /// 74.97 is what a 75 Hz CVT timing really runs at, so rates are compared
    /// and labelled as whole numbers.
    static func label(_ hz: Double) -> Int { Int(hz.rounded()) }
}

/// Keep and Revert are answers; a countdown that ran out is not.
enum RefreshRateAnswer {
    case keep
    case revert
    case timedOut
}

/// What the keep-or-revert dialog watches to tell a display that is still
/// renegotiating from one that has settled on the new mode.
struct DisplaySnapshot: Equatable {
    var isOnline: Bool
    var isActive: Bool
    var modeID: Int32
    var bounds: CGRect
}

// MARK: - EDID

/// One 18-byte detailed timing descriptor: the record an EDID uses to describe
/// a mode down to the pixel clock.
struct DetailedTiming: Equatable {
    var pixelClock10kHz: Int
    var hActive: Int
    var hBlank: Int
    var hFront: Int
    var hSync: Int
    var vActive: Int
    var vBlank: Int
    var vFront: Int
    var vSync: Int
    var hImageMM = 0
    var vImageMM = 0
    /// Digital separate sync, +hsync, -vsync: what reduced blanking calls for.
    var flags: UInt8 = 0x1A

    var isInterlaced: Bool { flags & 0x80 != 0 }
    var pixelClockMHz: Double { Double(pixelClock10kHz) / 100 }
    var hFreqKHz: Double { Double(pixelClock10kHz) * 10 / Double(hActive + hBlank) }
    var refreshHz: Double {
        let total = Double((hActive + hBlank) * (vActive + vBlank))
        return total > 0 ? Double(pixelClock10kHz) * 10_000 / total : 0
    }

    var bytes: [UInt8] {
        [UInt8(pixelClock10kHz & 0xFF), UInt8(pixelClock10kHz >> 8),
         UInt8(hActive & 0xFF), UInt8(hBlank & 0xFF),
         UInt8((hActive >> 8) << 4 | (hBlank >> 8)),
         UInt8(vActive & 0xFF), UInt8(vBlank & 0xFF),
         UInt8((vActive >> 8) << 4 | (vBlank >> 8)),
         UInt8(hFront & 0xFF), UInt8(hSync & 0xFF),
         UInt8((vFront & 0x0F) << 4 | (vSync & 0x0F)),
         UInt8((hFront >> 8) << 6 | (hSync >> 8) << 4 | (vFront >> 4) << 2 | (vSync >> 4)),
         UInt8(hImageMM & 0xFF), UInt8(vImageMM & 0xFF),
         UInt8((hImageMM >> 8) << 4 | (vImageMM >> 8)),
         0, 0, flags]
    }
}

extension DetailedTiming {
    /// Nil for a display descriptor (name, serial, range limits), which shares
    /// the slot but starts with a zero pixel clock.
    init?(_ b: [UInt8]) {
        guard b.count == 18 else { return nil }
        let clock = Int(b[0]) | Int(b[1]) << 8
        guard clock != 0 else { return nil }
        self.init(pixelClock10kHz: clock,
                  hActive: Int(b[2]) | Int(b[4] >> 4) << 8,
                  hBlank: Int(b[3]) | Int(b[4] & 0x0F) << 8,
                  hFront: Int(b[8]) | Int(b[11] >> 6) << 8,
                  hSync: Int(b[9]) | Int((b[11] >> 4) & 0x03) << 8,
                  vActive: Int(b[5]) | Int(b[7] >> 4) << 8,
                  vBlank: Int(b[6]) | Int(b[7] & 0x0F) << 8,
                  vFront: Int(b[10] >> 4) | Int((b[11] >> 2) & 0x03) << 4,
                  vSync: Int(b[10] & 0x0F) | Int(b[11] & 0x03) << 4,
                  hImageMM: Int(b[12]) | Int(b[14] >> 4) << 8,
                  vImageMM: Int(b[13]) | Int(b[14] & 0x0F) << 8,
                  flags: b[17])
    }

    /// VESA CVT 1.2 reduced blanking, the timing family monitors use for their
    /// high-refresh modes. Version 1 is what nearly every EDID carries;
    /// version 2 trims the blanking further and needs less bandwidth. Built
    /// to the letter of the spec (progressive, no margins), since a scaler
    /// that already runs past its comfort zone locks soonest onto the exact
    /// timing it was validated against.
    static func reducedBlanking(width: Int, height: Int, hz: Double, version: Int) -> DetailedTiming? {
        // RB_MIN_V_BLANK in µs and MIN_V_BPORCH in lines, common to both.
        let minVBlankMicroseconds = 460.0
        let minVBackPorch = 6
        // Version 1 works in 8-pixel character cells. A width that is not a
        // whole number of cells has no version 1 timing at its exact size.
        guard height > 0, version != 1 || width % 8 == 0 else { return nil }
        let hPeriodEstimate = (1_000_000 / hz - minVBlankMicroseconds) / Double(height)
        guard hPeriodEstimate > 0 else { return nil }
        // VBI_LINES = ROUNDDOWN(RB_MIN_V_BLANK / H_PERIOD_EST) + 1, both versions.
        let vbiLines = Int((minVBlankMicroseconds / hPeriodEstimate).rounded(.down)) + 1

        let hBlank, hFront, hSync, vSync, vFront, vBlank: Int
        if version == 1 {
            // Fixed 160-pixel blank: 48 front porch, 32 sync, 80 back porch.
            // Fixed 3-line front porch; sync width encodes the aspect ratio.
            (hBlank, hFront, hSync) = (160, 48, 32)
            vSync = cvtVSyncLines(width: width, height: height)
            vFront = 3
            vBlank = max(vbiLines, vFront + vSync + minVBackPorch)
        } else {
            // Fixed 80-pixel blank: 8 front porch, 32 sync, 40 back porch.
            // 8-line sync and 6-line back porch; the front porch takes the rest.
            (hBlank, hFront, hSync) = (80, 8, 32)
            vSync = 8
            vBlank = max(vbiLines, 1 + vSync + minVBackPorch)
            vFront = vBlank - vSync - minVBackPorch
        }

        let clockMHz = hz * Double((width + hBlank) * (height + vBlank)) / 1_000_000
        // Version 1 clocks come in 0.25 MHz steps. Rounding down keeps the
        // result at or just under the rate asked for, never over a limit.
        let stepped = version == 1 ? (clockMHz / 0.25).rounded(.down) * 0.25 : clockMHz
        let clock10kHz = Int((stepped * 100).rounded(.down))
        guard clock10kHz > 0, clock10kHz <= 0xFFFF, vFront < 64, vSync < 64 else { return nil }

        return DetailedTiming(pixelClock10kHz: clock10kHz,
                              hActive: width, hBlank: hBlank, hFront: hFront, hSync: hSync,
                              vActive: height, vBlank: vBlank, vFront: vFront, vSync: vSync)
    }

    /// CVT encodes the aspect ratio in the vsync width.
    static func cvtVSyncLines(width: Int, height: Int) -> Int {
        let ratio = Double(width) / Double(height)
        let table: [(Double, Int)] = [(4.0 / 3, 4), (16.0 / 9, 5), (16.0 / 10, 6), (5.0 / 4, 7), (15.0 / 9, 7)]
        return table.first { abs($0.0 - ratio) < 0.01 }?.1 ?? 10
    }
}

/// The monitor's own statement of what it can take, from the EDID's range
/// limits descriptor. Anything inside these is a rate the manufacturer signed
/// up for, even when they did not spell out a timing for it.
struct RangeLimits: Equatable {
    var minVHz: Int
    var maxVHz: Int
    var minHKHz: Int
    var maxHKHz: Int
    var maxPixelClockMHz: Int?
}

struct EDID: Equatable {
    var bytes: [UInt8]

    static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    static let baseDescriptorOffsets = [54, 72, 90, 108]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 128, bytes.count % 128 == 0, Array(bytes[0..<8]) == EDID.header else { return nil }
        self.bytes = bytes
    }

    var blockCount: Int { bytes.count / 128 }

    var preferredTiming: DetailedTiming? { DetailedTiming(Array(bytes[54..<72])) }

    var rangeLimits: RangeLimits? {
        for offset in EDID.baseDescriptorOffsets
        where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == 0xFD {
            let d = Array(bytes[offset..<offset + 18])
            // Byte 4 adds 255 to a limit that would not fit in a byte.
            let extra = { (bit: UInt8) in d[4] & bit != 0 ? 255 : 0 }
            return RangeLimits(minVHz: Int(d[5]) + extra(0x01),
                               maxVHz: Int(d[6]) + extra(0x02),
                               minHKHz: Int(d[7]) + extra(0x04),
                               maxHKHz: Int(d[8]) + extra(0x08),
                               maxPixelClockMHz: d[9] == 0 ? nil : Int(d[9]) * 10)
        }
        return nil
    }

    /// Start offsets of every CEA-861 extension block.
    var ceaBlocks: [Int] {
        (1..<max(blockCount, 1)).map { $0 * 128 }.filter { bytes[$0] == 0x02 }
    }

    /// Offsets of the timing descriptors in a CEA block, and where the next
    /// one would go.
    func ceaTimingSlots(_ base: Int) -> (used: [Int], next: Int)? {
        let start = Int(bytes[base + 2])
        guard start >= 4 else { return nil }
        var offset = base + start
        var used: [Int] = []
        while offset + 18 <= base + 127, bytes[offset] != 0 || bytes[offset + 1] != 0 {
            used.append(offset)
            offset += 18
        }
        return (used, offset)
    }

    var detailedTimings: [DetailedTiming] {
        var offsets = EDID.baseDescriptorOffsets
        for base in ceaBlocks {
            offsets += ceaTimingSlots(base)?.used ?? []
        }
        return offsets.compactMap { DetailedTiming(Array(bytes[$0..<$0 + 18])) }.filter { !$0.isInterlaced }
    }

    /// An HDMI input states the fastest link it takes, which can be lower than
    /// the range limits. Honouring it costs nothing over DisplayPort and keeps
    /// an HDMI adapter in the chain from being overdriven.
    var maxTMDSClockMHz: Int? {
        var hdmi: Int?
        var hdmiForum: Int?
        for base in ceaBlocks {
            let end = base + Int(bytes[base + 2])
            var pos = base + 4
            while pos < end {
                let tag = bytes[pos] >> 5
                let length = Int(bytes[pos] & 0x1F)
                if tag == 3, length >= 3 {
                    let oui = Int(bytes[pos + 1]) | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3]) << 16
                    if oui == 0x000C03, length >= 7, bytes[pos + 7] != 0 { hdmi = Int(bytes[pos + 7]) * 5 }
                    if oui == 0xC45DD8, length >= 5, bytes[pos + 5] != 0 { hdmiForum = Int(bytes[pos + 5]) * 5 }
                }
                pos += 1 + length
            }
        }
        return hdmiForum ?? hdmi
    }

    /// Whole-number rates this EDID spells out at a given pixel size.
    func ratesAt(width: Int, height: Int) -> Set<Int> {
        Set(detailedTimings.filter { $0.hActive == width && $0.vActive == height }
            .map { RefreshRateInfo.label($0.refreshHz) })
    }

    /// The highest common rate the range limits allow at the native resolution
    /// that is above everything macOS lists there. Every limit has to hold: the
    /// vertical rate, the line rate, the pixel clock and any HDMI link cap.
    func unlockCandidate(above listedHz: Int) -> (hz: Int, timing: DetailedTiming)? {
        guard let native = preferredTiming, let limits = rangeLimits,
              limits.maxVHz > 0, limits.maxHKHz > 0 else { return nil }
        let clockCap = [limits.maxPixelClockMHz, maxTMDSClockMHz].compactMap { $0 }.min()

        for hz in [240, 165, 144, 120, 100, 90, 85, 75, 72] where hz > listedHz && hz <= limits.maxVHz {
            for version in [1, 2] {
                guard var timing = DetailedTiming.reducedBlanking(width: native.hActive,
                                                                  height: native.vActive,
                                                                  hz: Double(hz),
                                                                  version: version) else { continue }
                guard timing.hFreqKHz <= Double(limits.maxHKHz) else { continue }
                if let cap = clockCap, timing.pixelClockMHz > Double(cap) { continue }
                timing.hImageMM = native.hImageMM
                timing.vImageMM = native.vImageMM
                return (hz, timing)
            }
        }
        return nil
    }

    /// A copy with `timing` added, placed where it disturbs the least: a free
    /// slot in a CEA block, else the CEA timing least worth keeping (one below
    /// 60 Hz first, then the smallest), else an unused base descriptor, else a
    /// new CEA block when there is none yet.
    func adding(_ timing: DetailedTiming) -> EDID? {
        var copy = self
        let record = timing.bytes

        for base in ceaBlocks {
            guard let slots = ceaTimingSlots(base) else { continue }
            let target: Int?
            if slots.next + 18 <= base + 127 {
                target = slots.next
            } else {
                target = slots.used.min { lhs, rhs in
                    let a = DetailedTiming(Array(bytes[lhs..<lhs + 18]))
                    let b = DetailedTiming(Array(bytes[rhs..<rhs + 18]))
                    let aSlow = (a?.refreshHz ?? 0) < 59
                    let bSlow = (b?.refreshHz ?? 0) < 59
                    if aSlow != bSlow { return aSlow }
                    return (a.map { $0.hActive * $0.vActive } ?? 0) < (b.map { $0.hActive * $0.vActive } ?? 0)
                }
            }
            if let target = target {
                copy.bytes.replaceSubrange(target..<target + 18, with: record)
                copy.fixChecksum(base)
                return copy
            }
        }

        for offset in EDID.baseDescriptorOffsets.dropFirst()
        where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == 0x10 {
            copy.bytes.replaceSubrange(offset..<offset + 18, with: record)
            copy.fixChecksum(0)
            return copy
        }

        guard blockCount == 1 else { return nil }
        var block: [UInt8] = [0x02, 0x03, 0x04, 0x00] + record
        block += [UInt8](repeating: 0, count: 128 - block.count)
        copy.bytes[126] = 1
        copy.fixChecksum(0)
        copy.bytes += block
        copy.fixChecksum(128)
        return copy
    }

    mutating func fixChecksum(_ base: Int) {
        let sum = bytes[base..<base + 127].reduce(0) { ($0 + Int($1)) & 0xFF }
        bytes[base + 127] = UInt8((256 - sum) & 0xFF)
    }
}

/// What the app knows about one monitor's EDID: the one it sends, and the one
/// a display override makes macOS use instead.
struct DisplayEDIDInfo {
    var vendor: UInt32
    var product: UInt32
    var hardware: EDID
    var override: EDID?
    var overrideDictionary: [String: Any]?

    var effective: EDID { override ?? hardware }
}

/// Display overrides are how an Intel Mac is told to use a different EDID:
/// a property list per vendor and product, read when the display connects.
/// Apple Silicon ignores the EDID in them, and has no IODisplayConnect to
/// read the original from, so there the unlock rows simply never appear.
enum DisplayOverride {
    static let root = "/Library/Displays/Contents/Resources/Overrides"

    static func directory(vendor: UInt32) -> String {
        "\(root)/DisplayVendorID-\(String(vendor, radix: 16))"
    }

    static func path(vendor: UInt32, product: UInt32) -> String {
        "\(directory(vendor: vendor))/DisplayProductID-\(String(product, radix: 16))"
    }

    static func read(vendor: UInt32, product: UInt32) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path(vendor: vendor, product: product)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The first time an override is touched, whatever was there is copied
    /// aside, so a hand-made one can always be put back.
    static func backUp(vendor: UInt32, product: UInt32) {
        let fm = FileManager.default
        let source = path(vendor: vendor, product: product)
        guard fm.fileExists(atPath: source),
              let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("AutoDisplayToggle/OverrideBackups", isDirectory: true)
        let backup = folder.appendingPathComponent("DisplayVendorID-\(String(vendor, radix: 16))-DisplayProductID-\(String(product, radix: 16)).plist")
        guard !fm.fileExists(atPath: backup.path) else { return }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: source, toPath: backup.path)
            Log.info(.override, "override backed up", ["source": source, "backup": backup.path])
        } catch {
            Log.error(.override, "override backup failed", ["source": source, "error": error.localizedDescription])
        }
    }

    enum Failure: Error {
        case cancelled
        case failed(String)
    }

    /// Writes `dictionary`, or deletes the override when it is nil. The folder
    /// belongs to root, so unless the file is already writable this goes
    /// through macOS's own administrator prompt.
    static func write(_ dictionary: [String: Any]?, vendor: UInt32, product: UInt32) throws {
        let fm = FileManager.default
        let file = path(vendor: vendor, product: product)
        let folder = directory(vendor: vendor)

        guard let dictionary = dictionary else {
            if !fm.fileExists(atPath: file) { return }
            if fm.isWritableFile(atPath: folder), (try? fm.removeItem(atPath: file)) != nil { return }
            try runPrivileged("rm -f \(shellQuoted(file))")
            return
        }

        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }

        // In place rather than atomically: an atomic write needs the folder,
        // and only the file may be ours.
        if fm.isWritableFile(atPath: file), (try? data.write(to: URL(fileURLWithPath: file))) != nil { return }
        if fm.isWritableFile(atPath: folder), (try? data.write(to: URL(fileURLWithPath: file), options: .atomic)) != nil { return }

        let staged = fm.temporaryDirectory.appendingPathComponent("AutoDisplayToggle-override-\(UUID().uuidString).plist")
        do {
            try data.write(to: staged)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: staged) }
        try runPrivileged("mkdir -p \(shellQuoted(folder)) && cp \(shellQuoted(staged.path)) \(shellQuoted(file)) && chmod 644 \(shellQuoted(file))")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func runPrivileged(_ command: String,
                              prompt: String = "AutoDisplayToggle wants to update a display override.") throws {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            Log.error(.override, "privileged script could not be compiled", ["command": command])
            throw Failure.failed("Could not prepare the request.")
        }
        script.executeAndReturnError(&error)
        guard let error = error else {
            Log.info(.override, "privileged command ran", ["command": command])
            return
        }
        let number = error[NSAppleScript.errorNumber] as? Int
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        if number == -128 {
            Log.info(.override, "administrator prompt cancelled", ["command": command])
            throw Failure.cancelled
        }
        Log.error(.override, "privileged command failed",
                  ["command": command, "code": number ?? 0, "error": message])
        throw Failure.failed(message)
    }
}

// MARK: - Power

/// Lid, power source and the system-wide sleep switch, read straight from
/// the power management root domain and IOPowerSources: no process to start,
/// cheap enough for a timer.
enum PowerState {
    private static func rootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    static var isLidClosed: Bool { rootDomainBool("AppleClamshellState") ?? false }
    /// Whether a closed lid sleeps the Mac right now. On an Intel notebook
    /// that is the case on battery, or with no external display.
    static var lidClosedCausesSleep: Bool { rootDomainBool("AppleClamshellCausesSleep") ?? true }
    /// `pmset disablesleep`, whoever set it.
    static var isSleepDisabled: Bool { rootDomainBool("SleepDisabled") ?? false }

    static func battery() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let source = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()).map { $0 as String }
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        var percent: Int?
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = current * 100 / maximum
        }
        return (source == kIOPSBatteryPowerValue, percent)
    }
}

/// The two pmset commands that need root, run without a prompt through a
/// sudoers rule the user installs once from the menu. `sudo -n` never asks
/// for a password: without the rule it fails, and the app says so.
enum SleepControl {
    static let sudoersPath = "/etc/sudoers.d/autodisplaytoggle"
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error(.sleep, "process could not start",
                      ["path": path, "args": arguments, "error": error.localizedDescription])
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let status = run(sudo, ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"])
        if status == 0 {
            Log.info(.sleep, disabled ? "system sleep disabled" : "system sleep enabled")
        } else {
            Log.error(.sleep, "pmset disablesleep failed", ["value": disabled, "status": status])
        }
        return status == 0
    }

    @discardableResult
    static func sleepNow() -> Bool {
        let status = run(sudo, ["-n", pmset, "sleepnow"])
        if status == 0 {
            Log.info(.sleep, "sleep requested (lid closed after sleep came back)")
        } else {
            Log.error(.sleep, "pmset sleepnow failed", ["status": status])
        }
        return status == 0
    }

    /// `sudo -l` with a command answers whether that exact command may run,
    /// and with -n it answers without asking for anything.
    static var isAuthorized: Bool {
        [["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"], ["sleepnow"]].allSatisfy {
            run(sudo, ["-n", "-l", pmset] + $0) == 0
        }
    }

    static func authorize() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw DisplayOverride.Failure.failed("The user name \(user) cannot go into a sudoers rule.")
        }
        // Exactly these three commands, with exactly these arguments.
        let rule = """
            # Installed by AutoDisplayToggle for "Stay awake with lid closed".
            # Lets \(user) switch system sleep off and on, and sleep the Mac, without a password.
            # Delete this file to take that back.
            \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1, \(pmset) sleepnow

            """
        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent("AutoDisplayToggle-sudoers-\(UUID().uuidString)")
        do {
            try rule.write(to: staged, atomically: true, encoding: .utf8)
        } catch {
            throw DisplayOverride.Failure.failed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: staged) }

        let q = DisplayOverride.shellQuoted
        // visudo checks the file before it goes live: a broken file in
        // sudoers.d would lock sudo out for every command, not just these.
        try DisplayOverride.runPrivileged(
            "/usr/sbin/visudo -cf \(q(staged.path)) && /usr/bin/install -m 0440 -o root -g wheel \(q(staged.path)) \(q(sudoersPath))",
            prompt: "AutoDisplayToggle wants to allow switching system sleep off while an external display is connected.")
    }
}

// MARK: - Desktop picture

/// macOS draws the desktop in two layers. WallpaperAgent renders the
/// picture itself into one window per display, and Dock keeps one desktop
/// window per display and Space above it. A burst of display changes (the
/// lid opening, the built-in panel coming and going, a resolution change)
/// can leave either of them laid out for a screen that is gone: the picture
/// shows cut off, or zoomed over part of the screen. Restarting the process
/// at fault is the fix macOS offers; launchd starts it again at once.
enum DesktopPicture {
    enum Owner: String {
        case dock = "com.apple.dock"
        case wallpaper = "com.apple.wallpaper.agent"
    }

    struct Misfit: Hashable {
        var owner: Owner
        var width: Int
        var height: Int
    }

    static func pid(_ owner: Owner) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: owner.rawValue).first?.processIdentifier
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Where every active display sits and how big it is. A change here is
    /// what desktop layers fail to follow.
    static func geometry() -> [String] {
        activeDisplays().map { id in
            let b = CGDisplayBounds(id)
            return "\(id):\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width))x\(Int(b.height))"
        }.sorted()
    }

    /// Desktop windows laid out for a screen that is not there. Three kinds:
    ///
    /// - A Dock or WallpaperAgent desktop window on any Space, parked at an
    ///   active display's corner but sized for another display. This is the
    ///   one seen in practice: when the built-in panel goes dark, Dock moves
    ///   the panel's desktop window onto the external display instead of
    ///   dropping it, and the picture shows at the panel's size over part of
    ///   the screen. Other Spaces count too, since switching to one shows it,
    ///   and nothing else would look again then.
    /// - Any on-screen one of theirs sized for no active display. Origins
    ///   wander while Spaces animate, so only the size is compared.
    /// - loginwindow's own desktop copy, when it sits in front of the picture
    ///   at the wrong size. Windows come front to back, which is how "in
    ///   front" is told.
    ///
    /// Bounds and owners are readable without Screen Recording permission;
    /// titles are not needed.
    static func misfits() -> [Misfit] {
        let displays = activeDisplays().map { CGDisplayBounds($0) }
        guard !displays.isEmpty else { return [] }
        var owners: [pid_t: Owner] = [:]
        for owner in [Owner.dock, .wallpaper] {
            if let pid = pid(owner) { owners[pid] = owner }
        }
        let loginWindowPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
            .first?.processIdentifier
        // Dock's own bar, Mission Control and the like sit far above this.
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        func desktopWindows(_ option: CGWindowListOption) -> [(pid: pid_t, bounds: CGRect)] {
            let list = (CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]) ?? []
            return list.compactMap { window in
                guard let ownerPID = (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                      let layer = window[kCGWindowLayer as String] as? Int, layer < desktopIconLevel,
                      let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
                return (ownerPID, bounds)
            }
        }
        func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }

        var found = Set<Misfit>()
        for (ownerPID, bounds) in desktopWindows([.optionAll]) {
            guard let owner = owners[ownerPID],
                  let display = displays.first(where: { abs($0.minX - bounds.minX) < 1 && abs($0.minY - bounds.minY) < 1 }),
                  !sameSize(display, bounds) else { continue }
            found.insert(Misfit(owner: owner, width: Int(bounds.width), height: Int(bounds.height)))
        }

        var pictureSeen = false
        for (ownerPID, bounds) in desktopWindows([.optionOnScreenOnly]) {
            let owner = owners[ownerPID]
            if owner == .wallpaper { pictureSeen = true }
            guard !displays.contains(where: { sameSize($0, bounds) }) else { continue }
            if let owner = owner {
                found.insert(Misfit(owner: owner, width: Int(bounds.width), height: Int(bounds.height)))
            } else if ownerPID == loginWindowPID, !pictureSeen {
                found.insert(Misfit(owner: .wallpaper, width: Int(bounds.width), height: Int(bounds.height)))
            }
        }
        return Array(found)
    }

    /// The same as `killall`; launchd starts it again at once.
    static func restart(_ owner: Owner) -> Bool {
        guard let pid = pid(owner) else {
            Log.warning(.desktop, "restart skipped, process not running", ["owner": owner.rawValue])
            return false
        }
        guard kill(pid, SIGTERM) == 0 else {
            Log.error(.desktop, "restart failed", ["owner": owner.rawValue, "errno": Int(errno)])
            return false
        }
        return true
    }
}

// MARK: - Display modes and UI size

/// One entry of the full mode list: a size in points, its pixel density and
/// its refresh rate, addressed by index. The public CGDisplayCopyAllDisplayModes
/// leaves out most HiDPI sizes a display override adds, and
/// CGConfigureDisplayWithDisplayMode refuses some it does list, so sizes are
/// read and set through the private calls System Settings uses.
struct ScaleMode: Equatable {
    var index: Int32
    var width: Int
    var height: Int
    var hz: Int
    var density: Float

    var isHiDPI: Bool { density > 1.5 }
    var pixelWidth: Int { Int((Float(width) * max(density, 1)).rounded()) }
    var sizeKey: String { "\(width)x\(height)\(isHiDPI ? " HiDPI" : "")" }

    /// The description record is 0xD4 bytes: width at 8, height at 12, the
    /// refresh rate at 190 and the density (2 for HiDPI) at 208.
    static let descriptionLength = 0xD4

    static func all(for id: CGDirectDisplayID) -> [ScaleMode] {
        var count: Int32 = 0
        guard CGSGetNumberOfDisplayModes(id, &count) == 0, count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: descriptionLength)
        var modes: [ScaleMode] = []
        for index in 0..<count {
            let status = bytes.withUnsafeMutableBytes {
                CGSGetDisplayModeDescriptionOfLength(id, index, $0.baseAddress!, Int32(descriptionLength))
            }
            guard status == 0 else { continue }
            let mode = bytes.withUnsafeBytes { raw in
                ScaleMode(index: index,
                          width: Int(raw.load(fromByteOffset: 8, as: UInt32.self)),
                          height: Int(raw.load(fromByteOffset: 12, as: UInt32.self)),
                          hz: Int(raw.load(fromByteOffset: 190, as: UInt16.self)),
                          density: raw.load(fromByteOffset: 208, as: Float.self))
            }
            if mode.width > 0 && mode.height > 0 { modes.append(mode) }
        }
        return modes
    }

    static func current(for id: CGDirectDisplayID, in modes: [ScaleMode]) -> ScaleMode? {
        var index: Int32 = -1
        let status = CGSGetCurrentDisplayMode(id, &index)
        guard status == 0 else {
            Log.error(.uiSize, "CGSGetCurrentDisplayMode failed", ["display": id, "code": status], throttle: 300)
            return nil
        }
        return modes.first { $0.index == index }
    }
}

/// Picks the size each display runs at so that text and controls come out
/// the same size to the eye on every one of them, instead of every app being
/// zoomed by hand after each move between screens. Sizes are compared in
/// points per inch of the physical panel, from its EDID.
enum UISize {
    /// Apple's own desktop displays (Studio Display, Pro Display XDR, iMac)
    /// open at about 109 points per inch. They sit further away than a
    /// laptop panel, which Apple runs denser.
    static let externalPointsPerInch = 109.0
    /// For a built-in panel that marks no default mode.
    static let builtinFallbackPointsPerInch = 127.0
    /// One slider step makes everything about 6% larger or smaller.
    static let stepFactor = 1.06
    static let steps = -3...3
    /// A scaled HiDPI size on an external display draws more pixels than the
    /// panel has and scales them down every frame. The panel's own pixels
    /// cost nothing extra, so they win unless a scaled size is clearly closer.
    static let scaledPenalty = 0.05

    static func target(base: Double, step: Int) -> Double {
        base / pow(stepFactor, Double(step))
    }

    /// How much larger than default one step setting makes things, e.g. "+12%".
    static func label(step: Int) -> String {
        guard step != 0 else { return "Default" }
        let percent = Int(((pow(stepFactor, Double(step)) - 1) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "−\(-percent)%"
    }

    /// `native` is the panel's own pixel size. It has to come from outside:
    /// the full list also holds every scaled framebuffer size, up to twice
    /// the panel in each direction, as low resolution modes.
    static func best(modes: [ScaleMode], current: ScaleMode, native: (width: Int, height: Int),
                     widthInches: Double, target: Double, isBuiltin: Bool, preferredHz: Int?) -> ScaleMode? {
        let nativeWidth = native.width
        let nativeAspect = Double(native.width) / Double(native.height)

        let candidates = modes.filter { mode in
            // Another aspect ratio would letterbox or stretch the picture.
            guard abs(Double(mode.width) / Double(mode.height) - nativeAspect) < 0.02 else { return false }
            if mode.isHiDPI { return true }
            // Low resolution only at the panel's own pixels: anything else
            // is stretched and blurry. A Retina panel at 1:1 is unreadable.
            return !isBuiltin && mode.width == nativeWidth
        }

        // One mode per size, at the rate the display runs or is pinned to.
        let picks = Dictionary(grouping: candidates, by: { $0.sizeKey }).values.compactMap { group -> ScaleMode? in
            if let hz = preferredHz, let mode = group.first(where: { abs($0.hz - hz) <= 1 }) { return mode }
            if let mode = group.first(where: { $0.hz == current.hz }) { return mode }
            return group.max { $0.hz < $1.hz }
        }

        func score(_ mode: ScaleMode) -> Double {
            var score = abs(log(Double(mode.width) / widthInches / target))
            if !isBuiltin && mode.isHiDPI && mode.pixelWidth != nativeWidth { score += scaledPenalty }
            return score
        }
        return picks.min { lhs, rhs in
            let (a, b) = (score(lhs), score(rhs))
            // Ties go to the larger size, for a stable answer.
            return a != b ? a < b : lhs.width > rhs.width
        }
    }
}

/// Why switching is off for now. A pause is an off that ends by itself, so it
/// lives beside the master switch rather than inside it.
enum PauseMode: Equatable {
    case timed
    case untilDisplayChange
}

/// Everything the menu shows, resolved in one go. Rendering from a single
/// snapshot is what keeps the menu bar icon, the header and the switch from
/// contradicting each other.
struct MenuState: Equatable {
    var isEnabled: Bool
    var displays: [DisplayInfo]
    var loginItem: LoginItemState
    var hotKeysRegistered: Bool
    var notificationsEnabled: Bool
    var restoreBrightness: Float
    var pauseMode: PauseMode?
    /// Whole minutes left on a timed pause. It belongs in the state so the
    /// countdown actually re-renders while the menu sits open.
    var pauseMinutesRemaining: Int?
    var refreshRates: [RefreshRateInfo]
    var preferHighestRefreshRate: Bool
    var matchUISize: Bool
    var uiSizeStep: Int
    var stayAwakeLidClosed: Bool
    /// This app has system sleep switched off right now.
    var lidAwakeActive: Bool
    var lidAwakeHeldForBattery: Bool

    /// Says whether the switch is doing anything at the moment, since sleep
    /// being off is the part worth knowing about.
    var lidAwakeHint: String? {
        guard stayAwakeLidClosed else { return nil }
        if lidAwakeHeldForBattery { return "low battery" }
        return lidAwakeActive ? "sleep off" : "no display"
    }

    /// Displays a pin keeps below their highest rate, so the switch can say
    /// why it is on while a monitor is not at the top.
    var pinnedBelowHighestCount: Int {
        refreshRates.filter { info in
            guard let pin = info.effectivePinHz, let top = info.autoTargetHz else { return false }
            return pin < top
        }.count
    }

    var internalDisplay: DisplayInfo? { displays.first { $0.isBuiltin } }
    var internalDisplayPresent: Bool { internalDisplay != nil }
    var internalDisplayActive: Bool { internalDisplay?.isShowing ?? false }
    var externalDisplayCount: Int { displays.filter { !$0.isBuiltin && $0.isShowing }.count }
    var isPaused: Bool { pauseMode != nil }

    var headerTitle: String {
        guard internalDisplayPresent else { return "Built-in display not detected" }
        if internalDisplay?.isMirrored == true { return "Internal display is mirroring" }
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

    /// One line covering both the switch and any pause, for the tooltip.
    var switchingSummary: String {
        guard let mode = pauseMode else {
            return isEnabled ? "Automatic switching is on" : "Automatic switching is off"
        }
        switch mode {
        case .timed:
            guard let minutes = pauseMinutesRemaining, minutes > 1 else { return "Paused, under a minute left" }
            return "Paused, \(minutes) minutes left"
        case .untilDisplayChange:
            return "Paused until the displays change"
        }
    }

    /// Spells out what "off" means here, since warnings are exempt from it.
    var notificationsHint: String? {
        notificationsEnabled ? nil : "warnings only"
    }

    /// The same thing in the few words that fit beside the resume row.
    var pauseHint: String? {
        guard let mode = pauseMode else { return nil }
        switch mode {
        case .timed:
            guard let minutes = pauseMinutesRemaining, minutes > 1 else { return "under a minute" }
            return "\(minutes) min left"
        case .untilDisplayChange:
            return "waiting on displays"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var isEnabled = true

    // شناسه‌ی مانیتور داخلی بعد از هر sleep/wake عوض می‌شود،
    // پس این مقدار فقط یک کش است و قبل از هر عملیات دوباره پیدا می‌شود.
    var internalDisplayID: CGDirectDisplayID = 0

    // The level the internal panel comes back to: captured from the panel while
    // it is lit, settable by hand from the menu, and remembered across launches
    // so a start with the panel already dark no longer has to guess.
    var savedBrightness: Float = 0.5 {
        didSet {
            guard savedBrightness != oldValue else { return }
            UserDefaults.standard.set(savedBrightness, forKey: Preference.restoreBrightness)
        }
    }

    var notificationsEnabled = true {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            UserDefaults.standard.set(notificationsEnabled, forKey: Preference.notificationsEnabled)
        }
    }
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
    var exitLogged = false

    var statusRow: MenuRowView!
    var switchingRow: MenuRowView!
    var brightnessRow: MenuRowView!
    var loginRow: MenuRowView!
    var notificationsRow: MenuRowView!
    var pauseHourRow: MenuRowView!
    var pauseUntilChangeRow: MenuRowView!
    var resumeRow: MenuRowView!
    var pauseHourItem: NSMenuItem!
    var pauseUntilChangeItem: NSMenuItem!
    var resumeItem: NSMenuItem!
    var displaysSeparatorItem: NSMenuItem!
    // A fixed pool, shown and hidden as displays come and go. Rebuilding the
    // rows on every refresh would throw away the view under the cursor.
    let maxDisplayRows = 5
    var displayRows: [MenuRowView] = []
    var displayRowItems: [NSMenuItem] = []
    var menuRows: [MenuRowView] = []
    var renderedMenuState: MenuState?
    /// What the menu bar icon last showed while the menu was closed.
    var renderedStatusState: MenuState?
    var isMenuOpen = false
    var lidAwakeRow: MenuRowView!

    // Stay awake with the lid closed: system sleep off while an external
    // display is connected. macOS on an Intel notebook only keeps a closed
    // Mac awake on power; on battery it sleeps, monitor or not.
    var stayAwakeLidClosed = false {
        didSet {
            guard stayAwakeLidClosed != oldValue else { return }
            UserDefaults.standard.set(stayAwakeLidClosed, forKey: Preference.stayAwakeLidClosed)
        }
    }
    /// What this app last set `disablesleep` to. Nil while it has not touched
    /// it, so a value somebody else set is left alone.
    var appliedSleepDisabled: Bool?
    var lidAwakeHeldForBattery = false
    var reportedSleepReleaseFailure = false
    let lidAwakeBatteryFloor = 10
    let lidAwakeBatteryResume = 15
    var lidAwakeTimer: Timer?
    var powerSourceRunLoopSource: CFRunLoopSource?

    // Desktop picture repair. A misfit has to survive a second look, and the
    // desktop is redrawn at most every half minute however often the
    // displays change; a repair held back by that runs once the time is up.
    var desktopCheckWorkItem: DispatchWorkItem?
    var lastDesktopRepair: Date?
    let desktopRepairMinimumInterval: TimeInterval = 30
    let desktopCheckSettleDelay: TimeInterval = 5
    let desktopCheckConfirmDelay: TimeInterval = 3
    /// The display layout the desktop was last known to match.
    var lastDesktopGeometry: [String]?
    /// Set whenever this app changes the layout itself, so a change that is
    /// undone within the settle time (the lid opening, then the panel going
    /// dark again) still gets its redraw.
    var desktopNeedsRedraw = false
    /// Misfits that came straight back after a restart. They are left alone
    /// until the layout changes, rather than restarting Dock forever.
    var repairedMisfits: Set<DesktopPicture.Misfit> = []
    /// Dock can move a stale desktop window into place well after a layout
    /// change has settled, so the desktop is looked at again later on too.
    let desktopFollowUpDelays: [TimeInterval] = [30, 90]
    var desktopFollowUpGeneration = 0
    var ignoredMisfits: Set<DesktopPicture.Misfit> = []

    // Matched UI size: every display at a size that makes the interface look
    // equally big, plus the user's offset in steps. A display is matched once
    // each time it appears; a size picked in System Settings afterwards stands
    // until the display comes back.
    var matchUISize = false {
        didSet {
            guard matchUISize != oldValue else { return }
            UserDefaults.standard.set(matchUISize, forKey: Preference.matchUISize)
        }
    }
    var uiSizeStep = 0 {
        didSet {
            guard uiSizeStep != oldValue else { return }
            UserDefaults.standard.set(uiSizeStep, forKey: Preference.uiSizeStep)
        }
    }
    /// displayKey to the size it was matched to while it has been active.
    var uiSizeMatched: [String: String] = [:]
    /// displayKey to a size picked by hand after matching. Kept across
    /// launches, so a login does not undo it.
    var uiSizeManual: [String: String] = [:] {
        didSet {
            guard uiSizeManual != oldValue else { return }
            UserDefaults.standard.set(uiSizeManual, forKey: Preference.uiSizeManual)
        }
    }
    /// The slider moved while the menu was open. Display sizes change once it
    /// closes: resizing the screen under an open menu would close it anyway.
    var uiSizeStepChanged = false
    /// displayKeys of the active displays at the last screen change.
    var lastActiveDisplayKeys: Set<String> = []
    /// A display joined or left since the last size pass. macOS resizes the
    /// others by itself then (the built-in panel lighting up on lid open
    /// shrinks the external one for a moment), so a size that differs from
    /// the matched one is macOS's doing, not a pick in System Settings.
    var activeDisplaysChangedSinceUISizeMatch = false
    var uiSizeWorkItem: DispatchWorkItem?
    var uiSizeForcePending = false
    var uiSizeRow: MenuRowView!
    var uiSizeSliderRow: MenuRowView!
    var uiSizeSliderItem: NSMenuItem!
    var menuRefreshTimer: Timer?
    // The hot keys are claimed after the menu is built, so the menu only
    // advertises a shortcut once it is really ours.
    var hotKeysRegistered = true

    // A pause is an off that ends by itself, either at a deadline or the next
    // time the displays change.
    var pauseMode: PauseMode?
    var pauseDeadline: Date?
    var pausedExternalCount = 0
    var pauseTimer: Timer?

    // Refresh rate section: a pool like the display rows, filled with one
    // header per external display followed by its rates.
    let maxRefreshRateRows = 16
    var refreshRateRows: [MenuRowView] = []
    var refreshRateRowItems: [NSMenuItem] = []
    var refreshRateSeparatorItem: NSMenuItem!
    var highestRateRow: MenuRowView!
    var highestRateItem: NSMenuItem!

    var preferHighestRefreshRate = false {
        didSet {
            guard preferHighestRefreshRate != oldValue else { return }
            UserDefaults.standard.set(preferHighestRefreshRate, forKey: Preference.preferHighestRefreshRate)
        }
    }
    // While the keep-or-revert dialog is up, nothing else may touch modes.
    var isConfirmingRefreshRate = false
    var refreshRateWorkItem: DispatchWorkItem?
    // A display that will not hold a rate would otherwise be retried on every
    // reconfiguration it causes, flickering forever.
    var lastAutoRefreshAttempt: [CGDirectDisplayID: Date] = [:]
    /// Monitors seen by the last enforcement pass. One missing from it has
    /// just appeared, and only those get their rate put right.
    var refreshRatePresentKeys: Set<String> = []
    let autoRefreshRetryInterval: TimeInterval = 30
    // An untested rate is offered once per launch; ignoring the dialog is not
    // an answer, so it is not remembered as one.
    var autoTrialsOffered: Set<String> = []
    var trustedRefreshRates: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(trustedRefreshRates), forKey: Preference.trustedRefreshRates) }
    }
    var rejectedRefreshRates: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(rejectedRefreshRates), forKey: Preference.rejectedRefreshRates) }
    }
    /// displayKey to whole-number Hz.
    var pinnedRefreshRates: [String: Int] = [:] {
        didSet {
            guard pinnedRefreshRates != oldValue else { return }
            UserDefaults.standard.set(pinnedRefreshRates, forKey: Preference.pinnedRefreshRates)
        }
    }
    // Reading the EDID walks the IORegistry, too slow for a once-a-second
    // menu refresh. Dropped whenever the displays change.
    var edidCache: [CGDirectDisplayID: DisplayEDIDInfo?] = [:]

    // A monitor can spend well over ten seconds hunting for its input after a
    // mode change, and macOS may not notice any of it. The countdown therefore
    // only starts once the display has stopped changing, restarts if it changes
    // again, and is long enough to outlast a hunt macOS never saw.
    let refreshRateSettleSeconds: TimeInterval = 3
    let refreshRateMaxSettleWait: TimeInterval = 20
    let refreshRateConfirmSeconds: TimeInterval = 45
    let refreshRateDialogLimit: TimeInterval = 120

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Log.launch()
        loadPreferences()
        resolveInternalDisplay()
        logDisplays("displays at launch")
        lastActiveDisplayKeys = Set(DesktopPicture.activeDisplays().map(displayKey))
        // A lit panel is a better answer than a remembered one, so this runs
        // after the stored level and overwrites it when it can read a real one.
        captureBrightness()
        setupMenu()
        setupPowerObservers()
        setupGlobalShortcuts() // میانبرهای سراسری
        setupTerminationHandlers()
        startMonitoring()
        scheduleRefreshRateEnforcement(after: 2.0)
        setupPowerSourceWatch()
        if stayAwakeLidClosed { startLidAwakeTimer() }
        updateLidAwake()
        scheduleUISizeMatch(after: 3)
        scheduleDesktopPictureCheck(after: 6)
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

        brightnessRow = MenuRowView(style: .slider)
        brightnessRow.onSliderChange = { [weak self] value in
            self?.setRestoreBrightness(Float(value))
        }
        // This row stays enabled: a view only receives mouse events while its
        // item is enabled, and the slider needs the drag.
        menu.addItem(rowItem(brightnessRow, accessibilityTitle: "Restore brightness"))

        pauseHourRow = MenuRowView(style: .single)
        pauseHourRow.content = MenuRowContent(symbolNames: ["pause.circle"],
                                              title: "Pause for 1 hour")
        pauseHourRow.onClick = { [weak self] in self?.pauseForAnHour() }
        pauseHourItem = rowItem(pauseHourRow, accessibilityTitle: "Pause for 1 hour")
        menu.addItem(pauseHourItem)

        pauseUntilChangeRow = MenuRowView(style: .single)
        pauseUntilChangeRow.content = MenuRowContent(symbolNames: ["pause.rectangle", "pause.circle"],
                                                     title: "Pause until displays change")
        pauseUntilChangeRow.onClick = { [weak self] in self?.pauseUntilDisplaysChange() }
        pauseUntilChangeItem = rowItem(pauseUntilChangeRow, accessibilityTitle: "Pause until displays change")
        menu.addItem(pauseUntilChangeItem)

        resumeRow = MenuRowView(style: .single)
        resumeRow.onClick = { [weak self] in self?.resumeNow() }
        resumeItem = rowItem(resumeRow, accessibilityTitle: "Resume now")
        menu.addItem(resumeItem)

        displaysSeparatorItem = NSMenuItem.separator()
        menu.addItem(displaysSeparatorItem)

        for _ in 0..<maxDisplayRows {
            let row = MenuRowView(style: .single)
            let item = rowItem(row, accessibilityTitle: "Display")
            // Reporting only, so arrow keys skip it.
            item.isEnabled = false
            item.isHidden = true
            displayRows.append(row)
            displayRowItems.append(item)
            menu.addItem(item)
        }

        refreshRateSeparatorItem = NSMenuItem.separator()
        menu.addItem(refreshRateSeparatorItem)

        for _ in 0..<maxRefreshRateRows {
            let row = MenuRowView(style: .single)
            let item = rowItem(row, accessibilityTitle: "Refresh rate")
            item.isHidden = true
            refreshRateRows.append(row)
            refreshRateRowItems.append(item)
            menu.addItem(item)
        }

        highestRateRow = MenuRowView(style: .single)
        highestRateRow.onClick = { [weak self] in self?.toggleHighestRefreshRate() }
        highestRateItem = rowItem(highestRateRow, accessibilityTitle: "Always use highest refresh rate")
        menu.addItem(highestRateItem)

        menu.addItem(NSMenuItem.separator())

        uiSizeRow = MenuRowView(style: .single)
        uiSizeRow.onClick = { [weak self] in self?.toggleMatchUISize() }
        menu.addItem(rowItem(uiSizeRow, accessibilityTitle: "Match UI size on all displays"))

        uiSizeSliderRow = MenuRowView(style: .slider)
        uiSizeSliderRow.setSliderStops(UISize.steps.count)
        uiSizeSliderRow.onSliderChange = { [weak self] value in
            self?.setUISizeStep(AppDelegate.uiSizeStep(forSliderValue: value))
        }
        // Enabled for the same reason as the brightness row: the slider
        // needs the drag.
        uiSizeSliderItem = rowItem(uiSizeSliderRow, accessibilityTitle: "UI size")
        menu.addItem(uiSizeSliderItem)

        menu.addItem(NSMenuItem.separator())

        notificationsRow = MenuRowView(style: .single)
        notificationsRow.onClick = { [weak self] in self?.toggleNotifications() }
        menu.addItem(rowItem(notificationsRow, accessibilityTitle: "Notifications"))

        lidAwakeRow = MenuRowView(style: .single)
        lidAwakeRow.onClick = { [weak self] in self?.toggleStayAwakeLidClosed() }
        menu.addItem(rowItem(lidAwakeRow, accessibilityTitle: "Stay awake with lid closed"))

        loginRow = MenuRowView(style: .single)
        loginRow.onClick = { [weak self] in self?.toggleLoginItem() }
        menu.addItem(rowItem(loginRow, accessibilityTitle: "Start at Login"))

        let logsRow = MenuRowView(style: .single)
        logsRow.content = MenuRowContent(symbolNames: ["doc.text.magnifyingglass", "doc.text"],
                                         title: "Show Logs")
        logsRow.onClick = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            self?.showLogs()
        }
        menu.addItem(rowItem(logsRow, accessibilityTitle: "Show Logs"))
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
        let fixedRows: [MenuRowView] = [statusRow, switchingRow, brightnessRow, pauseHourRow,
                                        pauseUntilChangeRow, resumeRow, notificationsRow, lidAwakeRow, loginRow,
                                        logsRow, uiSizeRow, uiSizeSliderRow,
                                        panicRow, quitRow, highestRateRow]
        menuRows = fixedRows + displayRows + refreshRateRows
        refreshMenu()
    }

    /// Reveals the log file in Finder. The display picture is written first,
    /// so the newest line always says what the screens look like right now.
    func showLogs() {
        logDisplays("logs opened")
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Log.file])
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
    ///
    /// With the menu closed only the menu bar icon is on screen, so only what
    /// the icon shows is read. The full survey copies every mode of every
    /// external display (well over a hundred on a QHD monitor) and asks the
    /// login item service for its status, and the reconcile loop would
    /// otherwise pay for that every five seconds around the clock.
    @objc func refreshMenu() {
        // menuRows is filled in last, so it stands for "the menu exists".
        guard statusItem != nil, !menuRows.isEmpty else { return }

        guard isMenuOpen else {
            let state = currentMenuState(full: false)
            guard state != renderedStatusState else { return }
            renderedStatusState = state
            renderStatusButton(state)
            return
        }

        let state = currentMenuState()
        guard state != renderedMenuState else { return }
        renderedMenuState = state
        renderedStatusState = nil
        render(state)
    }

    /// `full: false` leaves out the refresh rates and the login item, which
    /// only the open menu shows.
    func currentMenuState(full: Bool = true) -> MenuState {
        let displays = surveyDisplays()
        return MenuState(isEnabled: isEnabled,
                         displays: displays,
                         loginItem: full ? currentLoginItemState() : (renderedMenuState?.loginItem ?? .off),
                         hotKeysRegistered: hotKeysRegistered,
                         notificationsEnabled: notificationsEnabled,
                         restoreBrightness: savedBrightness,
                         pauseMode: pauseMode,
                         pauseMinutesRemaining: pauseMinutesRemaining,
                         refreshRates: full ? surveyRefreshRates(displays) : [],
                         preferHighestRefreshRate: preferHighestRefreshRate,
                         matchUISize: matchUISize,
                         uiSizeStep: uiSizeStep,
                         stayAwakeLidClosed: stayAwakeLidClosed,
                         lidAwakeActive: appliedSleepDisabled == true,
                         lidAwakeHeldForBattery: lidAwakeHeldForBattery)
    }

    /// Rounded up, so a pause with thirty seconds left still reads as a minute.
    var pauseMinutesRemaining: Int? {
        guard let deadline = pauseDeadline else { return nil }
        return max(Int((deadline.timeIntervalSinceNow / 60).rounded(.up)), 0)
    }

    /// One pass over the display list for everything the menu reports. The
    /// reconcile loop keeps its own reads, which answer a narrower question.
    func surveyDisplays() -> [DisplayInfo] {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &displays, &displayCount) == .success else { return [] }

        var found: [DisplayInfo] = []
        for i in 0..<Int(displayCount) {
            let id = displays[i]
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            found.append(DisplayInfo(id: id,
                                     isBuiltin: isBuiltin,
                                     isActive: CGDisplayIsActive(id) != 0,
                                     isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                                     name: displayName(for: id, isBuiltin: isBuiltin)))
        }

        // The built-in panel is the one this app acts on, so it leads the list.
        return found.sorted { lhs, rhs in
            lhs.isBuiltin != rhs.isBuiltin ? lhs.isBuiltin : lhs.id < rhs.id
        }
    }

    /// NSScreen only lists displays that are switched on, so a panel this app
    /// has disabled has no name to look up — which is exactly the state the menu
    /// exists to show. The built-in display therefore keeps a fixed label
    /// instead of one that disappears whenever it goes dark.
    func displayName(for id: CGDirectDisplayID, isBuiltin: Bool) -> String {
        if isBuiltin { return "Built-in display" }

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            if CGDirectDisplayID(number.uint32Value) == id { return screen.localizedName }
        }
        return "External display"
    }

    func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preference.notificationsEnabled) != nil {
            notificationsEnabled = defaults.bool(forKey: Preference.notificationsEnabled)
        }
        let stored = defaults.float(forKey: Preference.restoreBrightness)
        if stored > 0.01 { savedBrightness = stored }
        preferHighestRefreshRate = defaults.bool(forKey: Preference.preferHighestRefreshRate)
        trustedRefreshRates = Set(defaults.stringArray(forKey: Preference.trustedRefreshRates) ?? [])
        rejectedRefreshRates = Set(defaults.stringArray(forKey: Preference.rejectedRefreshRates) ?? [])
        if let stored = defaults.dictionary(forKey: Preference.pinnedRefreshRates) {
            pinnedRefreshRates = stored.compactMapValues { ($0 as? NSNumber)?.intValue }
        }
        matchUISize = defaults.bool(forKey: Preference.matchUISize)
        uiSizeManual = (defaults.dictionary(forKey: Preference.uiSizeManual) as? [String: String]) ?? [:]
        uiSizeStep = min(max(defaults.integer(forKey: Preference.uiSizeStep), UISize.steps.lowerBound),
                         UISize.steps.upperBound)
        stayAwakeLidClosed = defaults.bool(forKey: Preference.stayAwakeLidClosed)
        // A run that ended without a clean exit can leave sleep off; with the
        // switch on, that is taken as this app's doing, so it gets undone.
        if stayAwakeLidClosed, PowerState.isSleepDisabled { appliedSleepDisabled = true }
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

        brightnessRow.content = MenuRowContent(symbolNames: ["sun.max"],
                                               title: "Restore brightness",
                                               accessory: .slider(value: Double(state.restoreBrightness)),
                                               isInteractive: false)

        // Pausing an app that is already off means nothing, and resuming one
        // that was never paused means nothing either.
        pauseHourItem.isHidden = !state.isEnabled
        pauseUntilChangeItem.isHidden = !state.isEnabled
        resumeItem.isHidden = !state.isPaused
        resumeRow.content = MenuRowContent(symbolNames: ["play.circle"],
                                           title: "Resume now",
                                           hint: state.pauseHint)

        renderDisplayRows(state)
        renderRefreshRateRows(state)

        notificationsRow.content = MenuRowContent(symbolNames: [state.notificationsEnabled ? "bell" : "bell.slash"],
                                                  title: "Notifications",
                                                  hint: state.notificationsHint,
                                                  accessory: .toggle(isOn: state.notificationsEnabled))

        uiSizeRow.content = MenuRowContent(symbolNames: ["textformat.size", "textformat"],
                                           title: "Match UI size on all displays",
                                           accessory: .toggle(isOn: state.matchUISize))
        uiSizeSliderItem.isHidden = !state.matchUISize
        uiSizeSliderRow.content = MenuRowContent(symbolNames: ["plus.magnifyingglass", "textformat.size.larger"],
                                                 title: "UI size",
                                                 accessory: .slider(value: AppDelegate.sliderValue(forUISizeStep: state.uiSizeStep)),
                                                 sliderLabel: UISize.label(step: state.uiSizeStep),
                                                 isInteractive: false)

        lidAwakeRow.content = MenuRowContent(symbolNames: ["powersleep", "moon.zzz"],
                                             title: "Stay awake with lid closed",
                                             hint: state.lidAwakeHint,
                                             accessory: .toggle(isOn: state.stayAwakeLidClosed))

        loginRow.content = MenuRowContent(symbolNames: ["power"],
                                          title: "Start at Login",
                                          hint: state.loginApprovalHint,
                                          accessory: .toggle(isOn: state.loginItem == .on))

        normalizeRowWidths()
    }

    func renderDisplayRows(_ state: MenuState) {
        displaysSeparatorItem.isHidden = state.displays.isEmpty

        for (index, row) in displayRows.enumerated() {
            let item = displayRowItems[index]
            // The last row of the pool carries any overflow, so an unusually
            // large setup is reported rather than quietly cut off.
            let isOverflow = index == displayRows.count - 1 && state.displays.count > displayRows.count

            if isOverflow {
                item.isHidden = false
                row.content = MenuRowContent(symbolNames: ["ellipsis.circle"],
                                             title: "\(state.displays.count - index) more displays",
                                             isInteractive: false)
            } else if index < state.displays.count {
                let display = state.displays[index]
                item.isHidden = false
                row.content = MenuRowContent(symbolNames: display.isBuiltin ? ["laptopcomputer"] : ["display"],
                                             title: display.name,
                                             accessory: .detail(display.isMirrored ? "Mirrored" : display.isActive ? "On" : "Off"),
                                             isInteractive: false)
            } else {
                item.isHidden = true
            }
        }
    }

    /// Per external display: a header with the current rate, a row per rate it
    /// offers at this resolution, then whatever its EDID makes possible beyond
    /// that. A display with one rate and nothing to unlock gets the header only.
    func renderRefreshRateRows(_ state: MenuState) {
        let hasExternal = !state.refreshRates.isEmpty
        refreshRateSeparatorItem.isHidden = !hasExternal
        highestRateItem.isHidden = !hasExternal

        let pinned = state.pinnedBelowHighestCount
        highestRateRow.content = MenuRowContent(symbolNames: ["arrow.up.to.line.compact", "arrow.up.to.line"],
                                                title: "Always use highest rate",
                                                hint: state.preferHighestRefreshRate && pinned > 0
                                                    ? (state.refreshRates.count > 1 ? "\(pinned) pinned" : "pinned lower")
                                                    : nil,
                                                accessory: .toggle(isOn: state.preferHighestRefreshRate))

        // Each entry is the content of one pooled row plus what a click does.
        var entries: [(MenuRowContent, (() -> Void)?)] = []
        let showNames = state.refreshRates.count > 1

        for info in state.refreshRates {
            let displayID = info.displayID
            let name = info.name
            entries.append((MenuRowContent(symbolNames: ["speedometer", "gauge"],
                                           title: "Refresh rate",
                                           hint: showNames ? info.name : nil,
                                           accessory: .detail("\(info.currentLabel) Hz"),
                                           isInteractive: false), nil))

            if info.availableHz.count > 1 {
                for hz in info.availableHz {
                    let label = RefreshRateInfo.label(hz)
                    let isCurrent = label == info.currentLabel
                    // The current rate stays clickable while clicking it would
                    // pin it, so a rate that was set elsewhere can be kept.
                    let isInteractive = !isCurrent
                        || canPin(label, info, preferHighest: state.preferHighestRefreshRate)
                    entries.append((MenuRowContent(symbolNames: isCurrent ? ["checkmark"] : [],
                                                   title: "\(label) Hz",
                                                   hint: refreshRateHint(label, info),
                                                   isInteractive: isInteractive),
                                    { [weak self] in self?.chooseRefreshRate(hz, displayID: displayID, name: name) }))
                }
            }

            for hz in info.pendingHz {
                entries.append((MenuRowContent(symbolNames: ["cable.connector", "arrow.triangle.2.circlepath"],
                                               title: "\(hz) Hz unlocked",
                                               hint: "reconnect display",
                                               isInteractive: false), nil))
            }

            if let hz = info.unlockCandidateHz {
                entries.append((MenuRowContent(symbolNames: ["lock.open"],
                                               title: "Unlock \(hz) Hz…",
                                               hint: info.nativeSizeLabel),
                                { [weak self] in self?.unlockRefreshRate(displayID: displayID, name: name) }))
            }

            if !info.unlockedHz.isEmpty {
                entries.append((MenuRowContent(symbolNames: ["lock"],
                                               title: "Remove unlocked rates…"),
                                { [weak self] in self?.removeUnlockedRates(displayID: displayID, name: name) }))
            }
        }

        for (index, row) in refreshRateRows.enumerated() {
            let item = refreshRateRowItems[index]
            guard index < entries.count else {
                item.isHidden = true
                row.onClick = nil
                continue
            }
            let (content, action) = entries[index]
            item.isHidden = false
            // Rows that only report are skipped by the arrow keys.
            item.isEnabled = content.isInteractive
            row.content = content
            row.onClick = action
        }
    }

    /// One word on why a rate is special, most important first.
    func refreshRateHint(_ hz: Int, _ info: RefreshRateInfo) -> String? {
        if info.pinnedHz == hz { return "pinned" }
        if info.rejectedHz.contains(hz) { return "auto skips" }
        if info.needsTrial(hz) { return "untested" }
        if info.isNativeResolution && info.unlockedHz.contains(hz) { return "unlocked" }
        if let highest = info.highestHz, RefreshRateInfo.label(highest) == hz { return "highest" }
        return nil
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
        button.toolTip = "\(state.switchingSummary)\n\(state.headerTitle) · \(state.headerSubtitle)"
    }

    /// A menu is as wide as its widest item view, and each row draws its own
    /// highlight, so a row that kept a narrower width would highlight short of
    /// the others.
    func normalizeRowWidths() {
        // Clamped at the top end so one long monitor name cannot stretch the
        // whole menu; the name truncates instead.
        let width = min(max(menuRows.map { $0.contentWidth }.max() ?? 0, 240), 340)
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
            Log.error(.login, "login item change failed",
                      ["status": service.status.rawValue, "error": String(describing: error)])
            sendNotification(title: "Start at Login Failed",
                             message: "⚠️ \(error.localizedDescription)",
                             isWarning: true)
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
        Log.info(.user, enabled ? "switching on" : "switching off", ["wasEnabled": isEnabled])
        isEnabled = enabled
        // Touching the switch by hand settles the question, so a pause waiting
        // to undo it later is dropped. beginPause sets its state afterwards.
        clearPause()
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

    // ---------- Pause ----------

    @objc func pauseForAnHour() {
        beginPause(.timed, duration: 60 * 60)
    }

    @objc func pauseUntilDisplaysChange() {
        beginPause(.untilDisplayChange, duration: nil)
    }

    /// Off, but with an end in sight. Switching off is the same code path as the
    /// master switch, so the pause state is recorded after it rather than before.
    func beginPause(_ mode: PauseMode, duration: TimeInterval?) {
        setEnabled(false, notify: false)
        Log.info(.user, "paused", ["mode": String(describing: mode), "minutes": duration.map { Int($0 / 60) } ?? 0])

        pauseMode = mode
        pauseDeadline = duration.map { Date().addingTimeInterval($0) }
        pausedExternalCount = activeExternalCount()
        startPauseTimer()

        switch mode {
        case .timed:
            sendNotification(title: "Paused",
                             message: "⏸️ Internal display restored. Switching resumes in an hour.")
        case .untilDisplayChange:
            sendNotification(title: "Paused",
                             message: "⏸️ Internal display restored. Switching resumes when the displays change.")
        }

        refreshMenu()
    }

    @objc func resumeNow() {
        guard let mode = pauseMode else { return }
        Log.info(.user, "pause ended", ["mode": String(describing: mode)])
        setEnabled(true, notify: false)
        sendNotification(title: "AutoDisplayToggle On",
                         message: "⚡️ Pause over, automatic switching is active again.")
    }

    func clearPause() {
        pauseMode = nil
        pauseDeadline = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
    }

    func startPauseTimer() {
        pauseTimer?.invalidate()
        // Comparing against a stored deadline rather than trusting a single fire
        // keeps a pause honest across sleep, when timers do not run at all.
        let timer = Timer(timeInterval: 15,
                          target: self,
                          selector: #selector(checkPause),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    @objc func checkPause() {
        guard let mode = pauseMode else {
            pauseTimer?.invalidate()
            pauseTimer = nil
            return
        }

        switch mode {
        case .timed:
            if let deadline = pauseDeadline, Date() >= deadline {
                resumeNow()
                return
            }
        case .untilDisplayChange:
            if activeExternalCount() != pausedExternalCount {
                resumeNow()
                return
            }
        }

        // Keeps the countdown current for the tooltip and the resume row.
        refreshMenu()
    }

    func activeExternalCount() -> Int {
        surveyDisplays().filter { !$0.isBuiltin && $0.isShowing }.count
    }

    // ---------- Menu preferences ----------

    @objc func toggleNotifications() {
        notificationsEnabled = !notificationsEnabled
        // Only worth announcing through the channel being switched on; switching
        // it off silences the announcement anyway.
        if notificationsEnabled {
            sendNotification(title: "Notifications On",
                             message: "🔔 State changes will be announced again.")
        }
        refreshMenu()
    }

    /// The floor matches the one in setInternalEnabled: restoring the panel must
    /// never leave it black.
    func setRestoreBrightness(_ value: Float) {
        savedBrightness = min(max(value, 0.05), 1.0)
        refreshMenu()
    }

    // ---------- Refresh rate ----------

    func allDisplayModes(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        // Without the duplicates the HiDPI variants never show up at all.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// The modes that differ from `current` only in refresh rate, highest
    /// first, one per whole-number rate. Both the point and the pixel size have
    /// to match, or picking a rate would also flip a HiDPI mode to low
    /// resolution.
    func refreshModes(_ all: [CGDisplayMode], matching current: CGDisplayMode) -> [CGDisplayMode] {
        var byLabel: [Int: CGDisplayMode] = [:]
        for mode in all where mode.refreshRate > 0
            && mode.isUsableForDesktopGUI()
            && mode.width == current.width && mode.height == current.height
            && mode.pixelWidth == current.pixelWidth && mode.pixelHeight == current.pixelHeight {
            let label = RefreshRateInfo.label(mode.refreshRate)
            // The current mode wins its own slot, so re-picking it is a no-op.
            if byLabel[label] == nil || mode.ioDisplayModeID == current.ioDisplayModeID {
                byLabel[label] = mode
            }
        }
        return byLabel.values.sorted { $0.refreshRate > $1.refreshRate }
    }

    /// Vendor, product and serial: what tells one monitor from another across
    /// replugs, desks and display ID reshuffles.
    func displayKey(_ id: CGDirectDisplayID) -> String {
        "\(String(CGDisplayVendorNumber(id), radix: 16))-\(String(CGDisplayModelNumber(id), radix: 16))-\(CGDisplaySerialNumber(id))"
    }

    func edidInfo(for id: CGDirectDisplayID) -> DisplayEDIDInfo? {
        if let cached = edidCache[id] { return cached }
        let info = readEDIDInfo(for: id)
        // updateValue, because assigning nil through the subscript would drop
        // the entry instead of remembering that there is no EDID to read.
        edidCache.updateValue(info, forKey: id)
        return info
    }

    /// The EDID the monitor sends, found through IODisplayConnect by vendor,
    /// product and serial, plus the one its display override substitutes.
    /// macOS keeps reporting the monitor's own EDID while an override is in
    /// force, so the override has to be read from its file.
    func readEDIDInfo(for id: CGDirectDisplayID) -> DisplayEDIDInfo? {
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var hardware: EDID?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard hardware == nil else { continue }
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as NSDictionary
            guard (info["DisplayVendorID"] as? NSNumber)?.uint32Value == vendor,
                  (info["DisplayProductID"] as? NSNumber)?.uint32Value == product else { continue }
            if serial != 0, let other = (info["DisplaySerialNumber"] as? NSNumber)?.uint32Value,
               other != 0, other != serial {
                continue
            }
            let data = (info["IODisplayEDIDOriginal"] as? Data) ?? (info["IODisplayEDID"] as? Data)
            hardware = data.flatMap { EDID($0) }
        }
        guard let hardware = hardware else { return nil }

        let dictionary = DisplayOverride.read(vendor: vendor, product: product)
        let override = (dictionary?["IODisplayEDID"] as? Data).flatMap { EDID($0) }
        return DisplayEDIDInfo(vendor: vendor,
                               product: product,
                               hardware: hardware,
                               override: override == hardware ? nil : override,
                               overrideDictionary: dictionary)
    }

    func surveyRefreshRates(_ displays: [DisplayInfo]) -> [RefreshRateInfo] {
        displays.filter { !$0.isBuiltin && $0.isActive }.compactMap { display in
            guard let current = CGDisplayCopyDisplayMode(display.id), current.refreshRate > 0 else { return nil }
            let all = allDisplayModes(for: display.id)
            let rates = refreshModes(all, matching: current).map { $0.refreshRate }
            let available = rates.isEmpty ? [current.refreshRate] : rates

            let key = displayKey(display.id)
            var info = RefreshRateInfo(displayID: display.id,
                                       name: display.name,
                                       currentHz: current.refreshRate,
                                       availableHz: available,
                                       verdictKeyPrefix: "\(key)|\(current.pixelWidth)x\(current.pixelHeight)",
                                       displayKey: key,
                                       pinnedHz: pinnedRefreshRates[key],
                                       isNativeResolution: false,
                                       nativeSizeLabel: nil,
                                       unlockCandidateHz: nil,
                                       unlockedHz: [],
                                       pendingHz: [],
                                       trustedHz: [],
                                       rejectedHz: [])
            let labels = available.map(RefreshRateInfo.label)
            info.trustedHz = Set(labels.filter { trustedRefreshRates.contains(info.verdictKey($0)) })
            info.rejectedHz = Set(labels.filter { rejectedRefreshRates.contains(info.verdictKey($0)) })

            guard let edid = edidInfo(for: display.id), let native = edid.hardware.preferredTiming else { return info }
            let width = native.hActive
            let height = native.vActive
            info.nativeSizeLabel = "\(width)×\(height)"
            info.isNativeResolution = current.pixelWidth == width && current.pixelHeight == height

            // What macOS offers at the native size, at any HiDPI scale.
            let listedNative = Set(all.filter { $0.pixelWidth == width && $0.pixelHeight == height && $0.refreshRate > 0 }
                .map { RefreshRateInfo.label($0.refreshRate) })
            let hardwareRates = edid.hardware.ratesAt(width: width, height: height)
            let effectiveRates = edid.effective.ratesAt(width: width, height: height)

            info.unlockedHz = effectiveRates.subtracting(hardwareRates).sorted(by: >)
            info.pendingHz = info.unlockedHz.filter { !listedNative.contains($0) }
            let ceiling = max(listedNative.max() ?? 0, effectiveRates.max() ?? 0)
            info.unlockCandidateHz = edid.effective.unlockCandidate(above: ceiling)?.hz
            return info
        }
    }

    func refreshRateInfo(_ id: CGDirectDisplayID) -> RefreshRateInfo? {
        surveyRefreshRates(surveyDisplays()).first { $0.displayID == id }
    }

    @discardableResult
    func applyDisplayMode(_ mode: CGDisplayMode, to id: CGDirectDisplayID, option: CGConfigureOption) -> Bool {
        let fields: [String: Any] = ["display": id, "hz": mode.refreshRate, "modeID": mode.ioDisplayModeID,
                                     "size": "\(mode.width)x\(mode.height)"]
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            Log.error(.refreshRate, "CGBeginDisplayConfiguration failed", fields.merging(["code": begin.rawValue]) { $1 })
            return false
        }
        let configure = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            Log.error(.refreshRate, "CGConfigureDisplayWithDisplayMode failed", fields.merging(["code": configure.rawValue]) { $1 })
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, option)
        guard complete == .success else {
            Log.error(.refreshRate, "CGCompleteDisplayConfiguration failed", fields.merging(["code": complete.rawValue]) { $1 })
            return false
        }
        Log.info(.refreshRate, "mode applied", fields)
        return true
    }

    /// The mode for `hz` at the display's current size, looked up fresh: a mode
    /// object from an earlier survey may belong to a display ID that is gone.
    func refreshMode(_ hz: Double, on id: CGDirectDisplayID) -> (current: CGDisplayMode, target: CGDisplayMode)? {
        guard let current = CGDisplayCopyDisplayMode(id) else { return nil }
        let label = RefreshRateInfo.label(hz)
        guard let target = refreshModes(allDisplayModes(for: id), matching: current)
            .first(where: { RefreshRateInfo.label($0.refreshRate) == label }) else { return nil }
        return (current, target)
    }

    /// Clicking the rate a monitor already runs at pins it, unless that changes
    /// nothing: it is pinned already, or it is what "highest" picks anyway.
    func canPin(_ hz: Int, _ info: RefreshRateInfo, preferHighest: Bool) -> Bool {
        if info.pinnedHz == hz { return false }
        if preferHighest && info.pinnedHz == nil && info.autoTargetHz == hz { return false }
        return true
    }

    /// A rate row was clicked. The pick is pinned to this monitor, so neither a
    /// reconnect, a reboot nor "Always use highest rate" brings back a rate the
    /// user moved away from, for example one the panel skips frames at. While
    /// "highest" is on, picking the rate it would choose anyway lifts the pin.
    func chooseRefreshRate(_ hz: Double, displayID: CGDirectDisplayID, name: String) {
        // A row with a view has to dismiss the menu itself, and the dialog
        // that follows cannot run inside the menu's tracking loop.
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let info = self.refreshRateInfo(displayID) else { return }
            let label = RefreshRateInfo.label(hz)
            let isSwitch = label != info.currentLabel

            if isSwitch {
                // A rate the monitor claims, or one kept before, switches at
                // once; an untested unlock or a reverted rate is checked.
                guard self.tryRefreshRate(hz, displayID: displayID, name: name,
                                          confirm: info.needsConfirmation(label)) else { return }
            }

            if self.preferHighestRefreshRate && label == info.autoTargetHz {
                self.pinnedRefreshRates.removeValue(forKey: info.displayKey)
                if !isSwitch {
                    self.sendNotification(title: "Refresh Rate",
                                          message: "⤴️ \(name) follows the highest rate again.")
                }
            } else {
                self.pinnedRefreshRates[info.displayKey] = label
                if !isSwitch {
                    self.sendNotification(title: "Refresh Rate",
                                          message: "📌 \(name) stays at \(label) Hz from now on.")
                }
            }
            self.refreshMenu()
        }
    }

    /// Switches and, with `confirm`, asks whether the picture is fine and
    /// either keeps it or puts the old mode back. The answer is remembered for
    /// this monitor: a kept rate is trusted for silent switching, a reverted
    /// one is never chosen automatically again. Letting the dialog run out is
    /// not an answer.
    @discardableResult
    func tryRefreshRate(_ hz: Double, displayID: CGDirectDisplayID, name: String, confirm: Bool = true) -> Bool {
        guard !isConfirmingRefreshRate else { return false }
        guard let (previous, target) = refreshMode(hz, on: displayID) else {
            sendNotification(title: "Refresh Rate Unavailable",
                             message: "⚠️ \(name) no longer offers \(RefreshRateInfo.label(hz)) Hz at this resolution.",
                             isWarning: true)
            refreshMenu()
            return false
        }
        guard target.ioDisplayModeID != previous.ioDisplayModeID else { return true }

        let label = RefreshRateInfo.label(target.refreshRate)
        let verdictKey = refreshRateInfo(displayID)?.verdictKey(label)

        isConfirmingRefreshRate = true
        defer {
            isConfirmingRefreshRate = false
            refreshMenu()
        }

        // Written to the display preferences straight away. Making it stick
        // only after Keep would mean a second mode set, and with it a second
        // round of input hunting on the monitors that do that.
        guard applyDisplayMode(target, to: displayID, option: .permanently) else {
            sendNotification(title: "Refresh Rate Failed",
                             message: "⚠️ Could not switch \(name) to \(label) Hz.",
                             isWarning: true)
            return false
        }

        guard confirm else {
            sendNotification(title: "Refresh Rate", message: "⚡️ \(name) is now running at \(label) Hz.")
            return true
        }

        let answer = confirmRefreshRate(label: label, name: name, displayID: displayID, targetModeID: target.ioDisplayModeID)
        Log.info(.refreshRate, "trial answered", ["display": name, "hz": label, "answer": String(describing: answer)])
        switch answer {
        case .keep:
            if let key = verdictKey {
                trustedRefreshRates.insert(key)
                rejectedRefreshRates.remove(key)
            }
            sendNotification(title: "Refresh Rate", message: "⚡️ \(name) is now running at \(label) Hz.")
            return true
        case .revert:
            if let key = verdictKey {
                rejectedRefreshRates.insert(key)
                trustedRefreshRates.remove(key)
            }
        case .timedOut:
            break
        }

        applyDisplayMode(previous, to: displayID, option: .permanently)
        sendNotification(title: "Refresh Rate Reverted",
                         message: "↩️ \(name) is back at \(RefreshRateInfo.label(previous.refreshRate)) Hz.")
        return false
    }

    func displaySnapshot(_ id: CGDirectDisplayID) -> DisplaySnapshot {
        DisplaySnapshot(isOnline: CGDisplayIsOnline(id) != 0,
                        isActive: CGDisplayIsActive(id) != 0,
                        modeID: CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0,
                        bounds: CGDisplayBounds(id))
    }

    /// A Keep / Revert alert whose countdown waits for the display. It starts
    /// once the display has shown the new mode, unchanged, for a few seconds
    /// (or after a cap, for a monitor that hunts without macOS noticing),
    /// starts over whenever the display changes again, and picks Revert by
    /// itself when it runs out. The timer runs in the modal mode, since
    /// runModal spins the run loop in nothing else.
    func confirmRefreshRate(label: Int, name: String, displayID: CGDirectDisplayID, targetModeID: Int32) -> RefreshRateAnswer {
        let alert = NSAlert()
        alert.messageText = "Keep \(label) Hz on \(name)?"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert").keyEquivalent = "\u{1b}"

        // The longest text goes in first: an alert sizes itself when shown.
        let waitingText = "Waiting for \(name) to settle. Some monitors search their inputs for a while after a rate change, so the countdown only starts once the picture is back."
        let countdownText = { (seconds: Int) in
            "The previous rate comes back in \(seconds) second\(seconds == 1 ? "" : "s") unless you keep this one."
        }
        alert.informativeText = waitingText

        let start = Date()
        var waitingSince = start
        var lastChange = start
        var snapshot = displaySnapshot(displayID)
        var deadline: Date?

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let now = Date()
            let latest = self.displaySnapshot(displayID)
            if latest != snapshot {
                snapshot = latest
                lastChange = now
                if deadline != nil {
                    deadline = nil
                    waitingSince = now
                }
            }

            if deadline == nil {
                let settled = now.timeIntervalSince(lastChange) >= self.refreshRateSettleSeconds
                    && latest.isOnline && latest.isActive && latest.modeID == targetModeID
                if settled || now.timeIntervalSince(waitingSince) >= self.refreshRateMaxSettleWait {
                    deadline = now.addingTimeInterval(self.refreshRateConfirmSeconds)
                }
            }

            let remaining = deadline.map { Int($0.timeIntervalSince(now).rounded(.up)) }
            // A display that keeps flapping never settles; the hard limit is
            // what stops the dialog from waiting forever in front of a black
            // screen.
            if (remaining ?? 1) <= 0 || now.timeIntervalSince(start) >= self.refreshRateDialogLimit {
                timer.invalidate()
                NSApp.abortModal()
                return
            }
            alert.informativeText = remaining.map(countdownText) ?? waitingText
        }
        RunLoop.main.add(timer, forMode: .modalPanel)

        // A menu bar app is never frontmost on its own, and an alert behind
        // other windows would quietly revert.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()

        switch response {
        case .alertFirstButtonReturn: return .keep
        case .alertSecondButtonReturn: return .revert
        default: return .timedOut
        }
    }

    func toggleHighestRefreshRate() {
        statusItem.menu?.cancelTracking()
        preferHighestRefreshRate.toggle()
        refreshMenu()
        guard preferHighestRefreshRate else { return }
        // Switching it on is the moment the user is watching, so every change
        // it makes right now goes through the keep-or-revert check.
        DispatchQueue.main.async { [weak self] in
            self?.enforceRefreshRates(interactive: true)
        }
    }

    /// Debounced, like the reconcile: a replug or a wake fires a burst of
    /// screen-parameter changes and only the settled state matters.
    func scheduleRefreshRateEnforcement(after delay: TimeInterval) {
        refreshRateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.enforceRefreshRates() }
        refreshRateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Puts every external display back on the rate the user pinned for it,
    /// and, with "Always use highest rate" on, every unpinned one on the best
    /// rate it offers that the user has not turned down. A pin goes either way;
    /// "highest" only ever goes up. A rate the monitor lists itself, or one the
    /// user has kept before, is switched to quietly. One that only exists
    /// because of an unlock is offered once per launch with the keep-or-revert
    /// check. Runs whether or not automatic switching is on: the refresh rate
    /// is a separate matter from the built-in panel.
    func enforceRefreshRates(interactive: Bool = false) {
        guard !isSleeping, !isConfirmingRefreshRate else { return }

        let infos = surveyRefreshRates(surveyDisplays())
        let present = refreshRatePresentKeys
        refreshRatePresentKeys = Set(infos.map { $0.displayKey })

        for info in infos {
            // Rates are put right when a display appears: connected, at
            // launch, after a wake. A rate that changes while the display
            // stays connected was picked in System Settings or on the monitor,
            // so it becomes the pin instead of being forced back.
            if !interactive, present.contains(info.displayKey) {
                if let pin = info.pinnedHz, pin != info.currentLabel {
                    pinnedRefreshRates[info.displayKey] = info.currentLabel
                    sendNotification(title: "Refresh Rate",
                                     message: "📌 \(info.name) stays at \(info.currentLabel) Hz from now on, as set.")
                }
                continue
            }

            guard let target = info.targetHz(preferHighest: preferHighestRefreshRate),
                  target != info.currentLabel else { continue }
            let isPinned = info.effectivePinHz == target
            guard isPinned || target > info.currentLabel else { continue }

            if info.needsTrial(target) || (interactive && !isPinned) {
                let key = info.verdictKey(target)
                if !interactive {
                    guard !autoTrialsOffered.contains(key) else { continue }
                    autoTrialsOffered.insert(key)
                }
                tryRefreshRate(Double(target), displayID: info.displayID, name: info.name)
                continue
            }

            if let last = lastAutoRefreshAttempt[info.displayID],
               Date().timeIntervalSince(last) < autoRefreshRetryInterval {
                continue
            }
            lastAutoRefreshAttempt[info.displayID] = Date()

            guard let (_, mode) = refreshMode(Double(target), on: info.displayID),
                  applyDisplayMode(mode, to: info.displayID, option: .permanently) else {
                sendNotification(title: "Refresh Rate Failed",
                                 message: "⚠️ Could not switch \(info.name) to \(target) Hz.",
                                 isWarning: true)
                continue
            }
            sendNotification(title: "Refresh Rate",
                             message: isPinned
                                ? "📌 \(info.name) set back to \(target) Hz, the rate picked for it."
                                : "⚡️ \(info.name) set to \(target) Hz.")
        }
        refreshMenu()
    }

    // ---------- Unlocking rates ----------

    /// Adds the highest rate the monitor's own range limits allow at its native
    /// resolution to its display override, after saying exactly what will be
    /// written. Nothing switches here: macOS reads the override on the next
    /// connect, and the first switch to the new rate is a checked one.
    func unlockRefreshRate(displayID: CGDirectDisplayID, name: String) {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.edidCache.removeValue(forKey: displayID)

            guard let edid = self.edidInfo(for: displayID),
                  let native = edid.hardware.preferredTiming,
                  let limits = edid.effective.rangeLimits,
                  let hz = self.refreshRateInfo(displayID)?.unlockCandidateHz,
                  let candidate = edid.effective.unlockCandidate(above: hz - 1),
                  let patched = edid.effective.adding(candidate.timing) else {
                self.sendNotification(title: "Unlock Unavailable",
                                      message: "⚠️ \(name) has no rate left to unlock.",
                                      isWarning: true)
                self.refreshMenu()
                return
            }

            let timing = candidate.timing
            let alert = NSAlert()
            alert.messageText = "Unlock \(candidate.hz) Hz on \(name)?"
            alert.informativeText = """
                \(name) accepts up to \(limits.maxVHz) Hz and \(limits.maxHKHz) kHz by its own EDID, \
                but does not list \(candidate.hz) Hz at \(native.hActive)×\(native.vActive). This adds a \
                \(String(format: "%.2f", timing.refreshHz)) Hz timing (\(String(format: "%.2f", timing.pixelClockMHz)) MHz) \
                to its display override in /Library/Displays. macOS may ask for an administrator password.

                Reconnect the display or restart to use it. The first switch to \(candidate.hz) Hz asks you to keep or revert it.
                """
            alert.addButton(withTitle: "Unlock")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            var dictionary = edid.overrideDictionary ?? [:]
            if dictionary["DisplayVendorID"] == nil { dictionary["DisplayVendorID"] = Int(edid.vendor) }
            if dictionary["DisplayProductID"] == nil { dictionary["DisplayProductID"] = Int(edid.product) }
            dictionary["IODisplayEDID"] = Data(patched.bytes)

            guard self.writeOverride(dictionary, edid: edid, name: name) else { return }
            self.sendNotification(title: "\(candidate.hz) Hz Unlocked",
                                  message: "🔓 Reconnect \(name) or restart to use it.")
        }
    }

    /// Takes the EDID back out of the override and leaves the rest of it, such
    /// as HiDPI scale lists, alone.
    func removeUnlockedRates(displayID: CGDirectDisplayID, name: String) {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.edidCache.removeValue(forKey: displayID)
            guard let edid = self.edidInfo(for: displayID), var dictionary = edid.overrideDictionary else {
                self.refreshMenu()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Remove unlocked rates on \(name)?"
            alert.informativeText = "macOS goes back to the EDID \(name) sends itself. The rest of its display override stays. Reconnect the display or restart for it to take effect."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            dictionary.removeValue(forKey: "IODisplayEDID")
            let leftover = Set(dictionary.keys).subtracting(["DisplayVendorID", "DisplayProductID", "DisplayProductName"])
            guard self.writeOverride(leftover.isEmpty ? nil : dictionary, edid: edid, name: name) else { return }
            self.sendNotification(title: "Unlocked Rates Removed",
                                  message: "🔒 Reconnect \(name) or restart to finish.")
        }
    }

    func writeOverride(_ dictionary: [String: Any]?, edid: DisplayEDIDInfo, name: String) -> Bool {
        defer {
            edidCache.removeAll()
            refreshMenu()
        }
        DisplayOverride.backUp(vendor: edid.vendor, product: edid.product)
        do {
            try DisplayOverride.write(dictionary, vendor: edid.vendor, product: edid.product)
            return true
        } catch DisplayOverride.Failure.cancelled {
            return false
        } catch DisplayOverride.Failure.failed(let message) {
            sendNotification(title: "Display Override Failed", message: "⚠️ \(name): \(message)", isWarning: true)
            return false
        } catch {
            sendNotification(title: "Display Override Failed",
                             message: "⚠️ \(name): \(error.localizedDescription)",
                             isWarning: true)
            return false
        }
    }

    // ---------- Stay awake with lid closed ----------

    /// Switching it off flips in place. Switching it on explains what it costs
    /// first and may need the one-time administrator prompt, so the menu goes.
    func toggleStayAwakeLidClosed() {
        guard !stayAwakeLidClosed else {
            stayAwakeLidClosed = false
            stopLidAwakeTimer()
            updateLidAwake()
            sendNotification(title: "Normal Sleep",
                             message: "🌙 A closed Mac on battery sleeps again, monitor or not.")
            return
        }
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in self?.enableStayAwakeLidClosed() }
    }

    func enableStayAwakeLidClosed() {
        let alert = NSAlert()
        alert.messageText = "Stay awake with the lid closed?"
        alert.informativeText = """
            On battery, macOS sleeps this Mac when the lid closes, even with a monitor connected. \
            With this on, system sleep is switched off whenever an external display is connected, \
            so the lid can close on battery too. While it is off, the Mac does not sleep when idle \
            or from the Apple menu either. Displays still sleep.

            Sleep comes back as soon as the last external display is unplugged, and a closed Mac is \
            put to sleep right then. It also comes back below \(lidAwakeBatteryFloor)% battery. If \
            the app is force quit or crashes while sleep is off, sleep stays off until the app runs again.

            The first time, macOS asks for an administrator password to add a rule in \
            \(SleepControl.sudoersPath) that lets AutoDisplayToggle run "pmset disablesleep" and \
            "pmset sleepnow" without asking.
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if !SleepControl.isAuthorized {
            do {
                try SleepControl.authorize()
            } catch DisplayOverride.Failure.cancelled {
                return
            } catch DisplayOverride.Failure.failed(let message) {
                sendNotification(title: "Stay Awake Unavailable", message: "⚠️ \(message)", isWarning: true)
                return
            } catch {
                sendNotification(title: "Stay Awake Unavailable",
                                 message: "⚠️ \(error.localizedDescription)",
                                 isWarning: true)
                return
            }
            guard SleepControl.isAuthorized else {
                sendNotification(title: "Stay Awake Unavailable",
                                 message: "⚠️ The sudoers rule is in place but sudo does not accept it.",
                                 isWarning: true)
                return
            }
        }

        stayAwakeLidClosed = true
        reportedSleepReleaseFailure = false
        startLidAwakeTimer()
        updateLidAwake()
        sendNotification(title: "Stay Awake On",
                         message: "☕️ The lid can close on battery while a monitor is connected.")
    }

    /// Any external display that is connected, asleep or not. A display in
    /// display sleep is not active, and releasing sleep then would let a
    /// closed Mac sleep the moment its monitor dims.
    func hasOnlineExternal() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 }
    }

    func wantsSleepDisabled() -> Bool {
        guard stayAwakeLidClosed, hasOnlineExternal() else {
            lidAwakeHeldForBattery = false
            return false
        }
        // A floor and a higher resume point, so a battery hovering at the
        // floor does not switch sleep off and on with every percent.
        let power = PowerState.battery()
        if power.onBattery, let percent = power.percent {
            if percent <= lidAwakeBatteryFloor {
                lidAwakeHeldForBattery = true
            } else if percent >= lidAwakeBatteryResume {
                lidAwakeHeldForBattery = false
            }
        } else {
            lidAwakeHeldForBattery = false
        }
        return !lidAwakeHeldForBattery
    }

    /// Brings `disablesleep` in line with the switch, the displays and the
    /// battery. Cheap when nothing changes: sudo only runs on a change.
    @objc func updateLidAwake() {
        defer { refreshMenu() }

        if wantsSleepDisabled() {
            // Re-applied if somebody else switched sleep back on meanwhile.
            guard appliedSleepDisabled != true || !PowerState.isSleepDisabled else { return }
            if SleepControl.setSleepDisabled(true) {
                appliedSleepDisabled = true
                return
            }
            // The rule is gone or sudo changed. Normal sleep is the safe
            // place to land, rather than retrying quietly forever.
            stayAwakeLidClosed = false
            stopLidAwakeTimer()
            sendNotification(title: "Stay Awake Off",
                             message: "⚠️ Could not switch sleep off. Turn the switch on again to re-authorize.",
                             isWarning: true)
            return
        }

        guard appliedSleepDisabled == true else { return }
        guard SleepControl.setSleepDisabled(false) else {
            if !reportedSleepReleaseFailure {
                reportedSleepReleaseFailure = true
                sendNotification(title: "Sleep Still Off",
                                 message: "⚠️ Could not switch sleep back on. Run: sudo pmset -a disablesleep 0",
                                 isWarning: true)
            }
            return
        }
        appliedSleepDisabled = false
        reportedSleepReleaseFailure = false
        // The lid may have closed while sleep was off, say when the monitor
        // was unplugged on the way out. macOS does not look at the lid again
        // when sleep comes back, so a Mac headed for a bag is put to sleep.
        if PowerState.isLidClosed && PowerState.lidClosedCausesSleep {
            SleepControl.sleepNow()
        }
    }

    /// Catches what no notification reports, such as the battery crossing
    /// the floor between power source callbacks. Only runs while it matters.
    func startLidAwakeTimer() {
        stopLidAwakeTimer()
        let timer = Timer(timeInterval: 15, target: self, selector: #selector(updateLidAwake), userInfo: nil, repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        lidAwakeTimer = timer
    }

    func stopLidAwakeTimer() {
        lidAwakeTimer?.invalidate()
        lidAwakeTimer = nil
    }

    /// Plugging and unplugging the charger, straight from IOPowerSources.
    func setupPowerSourceWatch() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    // ---------- Desktop picture ----------

    /// Debounced like the reconcile: only the settled arrangement is worth
    /// judging, and Dock and WallpaperAgent need a moment after any change.
    func scheduleDesktopPictureCheck(after delay: TimeInterval? = nil, confirming: Bool = false) {
        desktopCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkDesktopPicture(confirming: confirming) }
        desktopCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? desktopCheckSettleDelay), execute: item)
    }

    /// The settled check, plus later looks that a newer change supersedes.
    func scheduleDesktopPictureChecksAfterLayoutChange() {
        scheduleDesktopPictureCheck()
        desktopFollowUpGeneration += 1
        let generation = desktopFollowUpGeneration
        for delay in desktopFollowUpDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.desktopFollowUpGeneration == generation else { return }
                self.scheduleDesktopPictureCheck(after: 0)
            }
        }
    }

    /// Redraws the desktop after the display layout changed, and restarts
    /// Dock when one of its desktop windows is sized for a screen that is not
    /// there. WallpaperAgent can keep the right window size with the wrong
    /// picture inside it, which nothing outside it can see, so every settled
    /// layout change gets a redraw: it costs a blink of the desktop picture.
    /// Whatever triggers a repair has to show up twice, a few seconds apart,
    /// so a Space switch or a change still in flight never counts.
    func checkDesktopPicture(confirming: Bool) {
        guard !isSleeping else { return }
        // Not under an open menu or a dialog: a restart would close or cover
        // them. Asked again once they are gone.
        guard !isMenuOpen, !isConfirmingRefreshRate else {
            scheduleDesktopPictureCheck()
            return
        }

        let geometry = DesktopPicture.geometry()
        let layoutChanged = lastDesktopGeometry.map { $0 != geometry } ?? false
        if layoutChanged { ignoredMisfits.removeAll() }

        let misfits = Set(DesktopPicture.misfits()).subtracting(ignoredMisfits)
        // A misfit that survived its own repair is not one a restart fixes.
        let stubborn = misfits.intersection(repairedMisfits)
        if !layoutChanged && !stubborn.isEmpty {
            Log.warning(.desktop, "misfit survived restart, ignoring until layout changes",
                        ["misfits": stubborn.map { "\($0.owner.rawValue) \($0.width)x\($0.height)" }.sorted()])
            ignoredMisfits.formUnion(stubborn)
            repairedMisfits.removeAll()
            return
        }

        let needsRedraw = layoutChanged || desktopNeedsRedraw
        guard needsRedraw || !misfits.isEmpty else {
            lastDesktopGeometry = geometry
            repairedMisfits.removeAll()
            return
        }
        guard confirming else {
            scheduleDesktopPictureCheck(after: desktopCheckConfirmDelay, confirming: true)
            return
        }
        if let last = lastDesktopRepair {
            let wait = desktopRepairMinimumInterval - Date().timeIntervalSince(last)
            if wait > 0 {
                scheduleDesktopPictureCheck(after: wait + 0.5, confirming: true)
                return
            }
        }

        lastDesktopRepair = Date()
        lastDesktopGeometry = geometry
        desktopNeedsRedraw = false
        repairedMisfits = misfits

        let wallpaperRestarted = DesktopPicture.restart(.wallpaper)
        let dockMisfit = misfits.first { $0.owner == .dock }
        let dockRestarted = dockMisfit != nil && DesktopPicture.restart(.dock)
        Log.info(.desktop, misfits.isEmpty ? "desktop redrawn after layout change" : "desktop repaired", [
            "layoutChanged": layoutChanged,
            "misfits": misfits.map { "\($0.owner.rawValue) \($0.width)x\($0.height)" }.sorted(),
            "wallpaperRestarted": wallpaperRestarted,
            "dockRestarted": dockRestarted,
            "layout": geometry,
        ])

        // A routine redraw after a layout change goes unannounced; a picture
        // that was visibly wrong does not.
        if let misfit = misfits.first, wallpaperRestarted || dockRestarted {
            sendNotification(title: "Desktop Picture Fixed",
                             message: "🖼️ It was drawn for a \(misfit.width)×\(misfit.height) screen and has been redrawn.")
        }
    }

    // ---------- UI size ----------

    static func sliderValue(forUISizeStep step: Int) -> Double {
        let span = Double(UISize.steps.count - 1)
        return 0.05 + Double(step - UISize.steps.lowerBound) * 0.95 / span
    }

    static func uiSizeStep(forSliderValue value: Double) -> Int {
        let span = Double(UISize.steps.count - 1)
        let step = Int(((value - 0.05) / 0.95 * span).rounded()) + UISize.steps.lowerBound
        return min(max(step, UISize.steps.lowerBound), UISize.steps.upperBound)
    }

    func toggleMatchUISize() {
        matchUISize.toggle()
        refreshMenu()
        guard matchUISize else { return }
        // Sizes change as soon as the menu is gone.
        statusItem.menu?.cancelTracking()
        uiSizeMatched.removeAll()
        uiSizeManual.removeAll()
        scheduleUISizeMatch(after: 0.3, force: true)
    }

    func setUISizeStep(_ step: Int) {
        guard step != uiSizeStep else { return }
        uiSizeStep = step
        uiSizeStepChanged = true
        refreshMenu()
    }

    /// Debounced like the reconcile, and after it: the built-in panel going
    /// dark is part of the layout this has to match.
    func scheduleUISizeMatch(after delay: TimeInterval = 3, force: Bool = false) {
        guard matchUISize else { return }
        // A forced pass must not be swallowed by a plain one scheduled later.
        let forcing = force || uiSizeForcePending
        uiSizeWorkItem?.cancel()
        uiSizeForcePending = forcing
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.uiSizeForcePending = false
            self.matchUISizes(force: forcing)
        }
        uiSizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The density Apple opens this built-in panel at, from the mode it
    /// marks as default: Apple sizes that for laptop viewing distance.
    func builtinDefaultPointsPerInch(_ id: CGDirectDisplayID, widthInches: Double) -> Double {
        let preferred = allDisplayModes(for: id).first {
            $0.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0 && $0.pixelWidth > $0.width
        }
        return preferred.map { Double($0.width) / widthInches } ?? UISize.builtinFallbackPointsPerInch
    }

    /// The panel's own pixels: the mode macOS flags as native, else the
    /// largest plain (not HiDPI) mode it offers for the desktop.
    func nativePixelSize(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let modes = allDisplayModes(for: id)
        if let native = modes.first(where: { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }) {
            return (native.pixelWidth, native.pixelHeight)
        }
        return modes.filter { $0.isUsableForDesktopGUI() && $0.pixelWidth == $0.width }
            .max { $0.width * $0.height < $1.width * $1.height }
            .map { ($0.width, $0.height) }
    }

    /// Puts every active display at the size closest to the shared target.
    /// `force` re-matches displays already matched while active, after the
    /// switch or the slider moved.
    func matchUISizes(force: Bool) {
        guard matchUISize, !isSleeping else { return }
        guard !isMenuOpen, !isConfirmingRefreshRate else {
            scheduleUISizeMatch(force: force)
            return
        }

        let active = DesktopPicture.activeDisplays()
        let activeKeys = Set(active.map(displayKey))
        // A display that went away is matched again when it comes back.
        uiSizeMatched = uiSizeMatched.filter { activeKeys.contains($0.key) }
        let layoutChurned = activeDisplaysChangedSinceUISizeMatch
        activeDisplaysChangedSinceUISizeMatch = false

        for id in active {
            let key = displayKey(id)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            // A projector or TV whose EDID has no physical size gives nothing
            // to match against.
            let millimetres = CGDisplayScreenSize(id)
            guard millimetres.width > 100 else { continue }
            let widthInches = Double(millimetres.width) / 25.4

            let modes = ScaleMode.all(for: id)
            guard let current = ScaleMode.current(for: id, in: modes) else { continue }
            let base = isBuiltin
                ? builtinDefaultPointsPerInch(id, widthInches: widthInches)
                : UISize.externalPointsPerInch
            guard let native = nativePixelSize(id),
                  let best = UISize.best(modes: modes,
                                         current: current,
                                         native: native,
                                         widthInches: widthInches,
                                         target: UISize.target(base: base, step: uiSizeStep),
                                         isBuiltin: isBuiltin,
                                         preferredHz: pinnedRefreshRates[key]) else { continue }

            let name = displayName(for: id, isBuiltin: isBuiltin)
            if !force {
                // Picked by hand earlier: left alone.
                if uiSizeManual[key] != nil { continue }
                // After a display joined or left, a changed size is matched
                // again below instead of being taken for a pick.
                if let matched = uiSizeMatched[key], !layoutChurned {
                    // Matched while active and changed since: the user chose
                    // that size in System Settings, so it is kept from now on.
                    if matched != current.sizeKey {
                        uiSizeManual[key] = current.sizeKey
                        sendNotification(title: "UI Size",
                                         message: "📌 Keeping \(name) at \(current.width)×\(current.height) as picked. Move the UI size slider to match it again.")
                    }
                    continue
                }
            }
            uiSizeMatched[key] = best.sizeKey
            guard best.sizeKey != current.sizeKey else { continue }

            if applyScaleMode(best, to: id) {
                sendNotification(title: "UI Size",
                                 message: "📐 \(name) now looks like \(best.width)×\(best.height) (\(Int((Double(best.width) / widthInches).rounded())) points per inch).")
            } else {
                // Recorded as is, so a failure is neither retried on every
                // display change nor mistaken for a size picked by hand.
                uiSizeMatched[key] = current.sizeKey
                sendNotification(title: "UI Size Failed",
                                 message: "⚠️ Could not set \(name) to \(best.width)×\(best.height).",
                                 isWarning: true)
            }
        }
        refreshMenu()
    }

    /// Saved permanently, so macOS opens the display at this size on the
    /// next connect by itself and there is nothing left to change then.
    func applyScaleMode(_ mode: ScaleMode, to id: CGDirectDisplayID) -> Bool {
        let fields: [String: Any] = ["display": id, "size": mode.sizeKey, "hz": mode.hz, "index": mode.index]
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            Log.error(.uiSize, "CGBeginDisplayConfiguration failed", fields.merging(["code": begin.rawValue]) { $1 })
            return false
        }
        let configure = CGSConfigureDisplayMode(config, id, mode.index)
        guard configure == 0 else {
            CGCancelDisplayConfiguration(config)
            Log.error(.uiSize, "CGSConfigureDisplayMode failed", fields.merging(["code": configure]) { $1 })
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            Log.error(.uiSize, "CGCompleteDisplayConfiguration failed", fields.merging(["code": complete.rawValue]) { $1 })
            return false
        }
        desktopNeedsRedraw = true
        Log.info(.uiSize, "size applied", fields)
        return true
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
                             message: "⚠️ ⌃⌥⌘D / ⌃⌥⌘E are already claimed by another app.",
                             isWarning: true)
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

        guard status == noErr, let ref = ref else {
            Log.error(.hotKey, "RegisterEventHotKey failed", ["id": id, "keyCode": keyCode, "code": Int(status)])
            return false
        }
        hotKeyRefs.append(ref)
        return true
    }

    func handleHotKey(_ id: UInt32) {
        Log.info(.hotKey, "hot key pressed", ["key": id == hotKeyIDTurnOff ? "⌃⌥⌘D" : "⌃⌥⌘E"])
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
        Log.warning(.user, "panic reset", ["wasEnabled": isEnabled])
        // setEnabled(false) خودش مانیتور داخلی را برمی‌گرداند؛ اطلاع‌رسانی‌اش را
        // خاموش می‌کنیم تا دو نوتیفیکیشن پشت سر هم نیاید.
        if isEnabled { setEnabled(false, notify: false) }
        else { _ = setInternalEnabled(true) }
        sendNotification(title: "Panic Reset",
                         message: "✅ Internal display restored. Press ⌃⌥⌘E to turn switching back on.")
    }

    @objc func quitApp() {
        restoreBeforeExit(reason: "quit")
        NSApplication.shared.terminate(nil)
    }

    // اگر برنامه بدون بازگرداندن نور بسته شود، مانیتور داخلی سیاه و خاموش می‌ماند.
    // پس در همه‌ی مسیرهای خروج (منو، Apple Event، SIGTERM) آن را برمی‌گردانیم.
    func applicationWillTerminate(_ aNotification: Notification) {
        restoreBeforeExit(reason: "terminate")
    }

    func restoreBeforeExit(reason: String) {
        // Quit runs this and then terminate runs it again; one exit line is enough.
        defer {
            if !exitLogged {
                exitLogged = true
                Log.exited(reason)
            }
        }
        isEnabled = false
        stopMonitoring()
        if internalPanelOnline() {
            _ = setInternalEnabled(true)
        }
        // Sleep must never stay off without the app here to switch it back.
        stopLidAwakeTimer()
        if appliedSleepDisabled == true, SleepControl.setSleepDisabled(false) {
            appliedSleepDisabled = false
        }
    }

    func setupTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreBeforeExit(reason: "signal \(sig)")
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

    // Warnings ignore the Notifications switch: silencing routine state changes
    // should not also hide a failure the user has to act on.
    func sendNotification(title: String, message: String, isWarning: Bool = false) {
        // Logged whether or not it is shown: what the user was told is part of
        // what happened, and silencing notifications must not blank the log.
        if isWarning {
            Log.warning(.notification, title, ["message": message])
        } else {
            Log.info(.notification, title, ["message": message, "shown": notificationsEnabled])
        }
        guard notificationsEnabled || isWarning else { return }

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
        UNUserNotificationCenter.current().add(request) { error in
            guard let error = error else { return }
            Log.error(.notification, "notification delivery failed", ["title": title, "error": error.localizedDescription])
        }
    }

    // مسیر جایگزین: بدون بانْدل یا بدون مجوز نوتیفیکیشن
    func sendNotificationViaAppleScript(title: String, message: String) {
        let safeTitle = appleScriptLiteral(title)
        let safeMessage = appleScriptLiteral(message)
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "display notification \(safeMessage) with title \(safeTitle)"]
            do {
                try task.run()
            } catch {
                Log.error(.notification, "osascript notification failed", ["title": title, "error": error.localizedDescription])
            }
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
    // A hardware mirror set reports only its primary as active, so an external
    // display mirroring the built-in panel counts as connected too.
    func hasActiveExternal() -> Bool {
        onlineDisplays().contains { id in
            CGDisplayIsBuiltin(id) == 0 && (CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    func onlineDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        let status = CGGetOnlineDisplayList(16, &displays, &displayCount)
        guard status == .success else {
            Log.error(.display, "CGGetOnlineDisplayList failed", ["code": status.rawValue], throttle: 60)
            return []
        }
        return Array(displays.prefix(Int(displayCount)))
    }

    /// The display picture a log line is read against: what is connected,
    /// what is showing, and where.
    func logDisplays(_ message: String) {
        let online = onlineDisplays()
        let builtin = online.first { CGDisplayIsBuiltin($0) != 0 }
        Log.info(.display, message, [
            "online": online.count,
            "externalActive": online.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }.count,
            "builtinPresent": builtin != nil,
            "builtinShowing": builtin.map(internalIsShowing) ?? false,
            "lidClosed": PowerState.isLidClosed,
            "layout": DesktopPicture.geometry(),
        ])
    }

    /// The built-in panel still takes part in the desktop: switched on, or in a
    /// mirror set. A hardware mirror secondary reports itself inactive while
    /// WindowServer keeps scaling every frame onto it, so active alone misses it.
    func internalIsShowing(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0
    }

    /// Every display that would have to stop mirroring for the built-in panel
    /// to leave its mirror set: the panel itself when it mirrors another
    /// display, and each display that mirrors the panel. A hardware set led by
    /// the panel is also matched by its primary, in case a secondary does not
    /// name it. Externals mirroring each other are left alone.
    func internalMirrorSecondaries(_ builtin: CGDirectDisplayID) -> [CGDirectDisplayID] {
        guard CGDisplayIsInMirrorSet(builtin) != 0 else { return [] }
        let internalLeads = CGDisplayPrimaryDisplay(builtin) == builtin
            && CGDisplayMirrorsDisplay(builtin) == kCGNullDirectDisplay
        let secondaries = onlineDisplays().filter { id in
            guard CGDisplayIsInMirrorSet(id) != 0 else { return false }
            let isSecondary = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay || CGDisplayPrimaryDisplay(id) != id
            guard isSecondary else { return false }
            return id == builtin
                || CGDisplayMirrorsDisplay(id) == builtin
                || (internalLeads && CGDisplayPrimaryDisplay(id) == builtin)
        }
        return secondaries.isEmpty ? [builtin] : secondaries
    }

    /// Takes the built-in panel out of any mirror set. Mirroring a Retina panel
    /// onto a monitor at another resolution and refresh rate means a scaled
    /// composite every frame, timed to two clocks at once, which is where the
    /// stutter in window switching and Mission Control comes from. Saved
    /// permanently, so the next connect does not mirror again; the panel itself
    /// is only switched off for the session.
    func breakInternalMirroring(_ builtin: CGDirectDisplayID) -> Bool {
        let secondaries = internalMirrorSecondaries(builtin)
        guard !secondaries.isEmpty else { return true }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            Log.error(.mirroring, "CGBeginDisplayConfiguration failed", ["code": begin.rawValue])
            return false
        }
        for id in secondaries {
            let status = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            guard status == .success else {
                CGCancelDisplayConfiguration(config)
                Log.error(.mirroring, "CGConfigureDisplayMirrorOfDisplay failed", ["display": id, "code": status.rawValue])
                return false
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            Log.error(.mirroring, "CGCompleteDisplayConfiguration failed", ["code": complete.rawValue])
            return false
        }
        Log.info(.mirroring, "mirroring broken", ["secondaries": secondaries.map { Int($0) }])
        desktopNeedsRedraw = true
        sendNotification(title: "Mirroring Off", message: "🪞 Stopped mirroring the internal display.")
        return true
    }

    /// Only a panel that is showing a picture says anything about the level
    /// the user wants. A switched-off panel's backlight still drifts up with
    /// ambient light or a wake, and taking that drift for a choice is how the
    /// restore level crept down to a few percent.
    func captureBrightness() {
        guard internalDisplayID != 0, internalIsShowing(internalDisplayID) else { return }
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
        let showing = internalIsShowing(id)
        let read = DisplayServicesGetBrightness(id, &level)
        if read == 0 {
            if level <= 0.001 { return true } // از قبل صفر است
            // ترجیح کاربر را فقط وقتی پنل هنوز تصویر دارد نگه می‌داریم؛
            // نوری که روی پنل خاموش بالا رفته انتخاب کاربر نیست.
            if level > 0.01, showing { savedBrightness = level }
        } else {
            Log.error(.brightness, "DisplayServicesGetBrightness failed", ["display": id, "code": read], throttle: 60)
        }
        let status = DisplayServicesSetBrightness(id, 0.0)
        guard status == 0 else {
            Log.error(.brightness, "DisplayServicesSetBrightness(0) failed", ["display": id, "code": status], throttle: 60)
            return false
        }
        // A panel already switched off whose backlight came back on by itself
        // (wake, ambient light sensor) is the drift this loop exists for.
        Log.info(.brightness, showing ? "backlight zeroed before switch-off" : "backlight crept up on a dark panel, zeroed",
                 ["display": id, "from": read == 0 ? Double(level) : -1], throttle: showing ? nil : 60)
        return true
    }

    // ---------- اعمال وضعیت ----------

    func setInternalEnabled(_ enabled: Bool) -> Bool {
        let id = resolveInternalDisplay()
        guard id != 0 else {
            Log.warning(.display, "built-in display not found", ["wanted": enabled ? "on" : "off"], throttle: 60)
            return false
        }

        // قبل از خاموش کردن نور را صفر می‌کنیم تا در لحظه‌ی تغییر، پنل روشن نماند
        if !enabled {
            enforceZeroBrightness(id)
            // A panel in a mirror set cannot simply be switched off: as the
            // primary it takes the desktop with it, as a secondary the switch
            // does not stick. Mirroring goes first, in its own transaction,
            // because it is saved permanently and the switch-off is not.
            guard breakInternalMirroring(id) else { return false }
        }

        let wanted = enabled ? "on" : "off"
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else {
            Log.error(.display, "CGBeginDisplayConfiguration failed", ["wanted": wanted, "code": begin.rawValue])
            return false
        }

        let configure = CGSConfigureDisplayEnabled(config, id, enabled)
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            Log.error(.display, "CGSConfigureDisplayEnabled failed",
                      ["display": id, "wanted": wanted, "code": configure.rawValue])
            return false
        }

        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else {
            Log.error(.display, "CGCompleteDisplayConfiguration failed",
                      ["display": id, "wanted": wanted, "code": complete.rawValue])
            return false
        }
        desktopNeedsRedraw = true

        if enabled {
            // کف امنیتی تا در صورت خراب بودن مقدار ذخیره‌شده، صفحه سیاه نماند
            let level = max(savedBrightness, 0.05)
            let status = DisplayServicesSetBrightness(id, level)
            guard status == 0 else {
                Log.error(.brightness, "brightness restore failed", ["display": id, "level": level, "code": status])
                return false
            }
            return true
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

        // Mirrored counts as on: a hardware mirror secondary reports itself
        // inactive, and taking that at its word left the panel mirrored for good.
        let actual = internalIsShowing(id)
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
                    Log.error(.display, "switching keeps failing, cooling down",
                              ["failures": failureCount, "cooldownSeconds": Int(failureCooldown), "wanted": desired ? "on" : "off"])
                    sendNotification(title: "Display Toggle Failed",
                                     message: "⚠️ Could not switch the internal display. Retrying shortly.",
                                     isWarning: true)
                }
                return
            }
            failureCount = 0
        }

        isApplying = true
        let started = Date()
        let ok = setInternalEnabled(desired)
        isApplying = false
        // One line per attempt: how often switching happens, how long it
        // takes, and how many tries a change needs.
        let fields: [String: Any] = ["wanted": desired ? "on" : "off",
                                     "ms": Int(Date().timeIntervalSince(started) * 1000),
                                     "attempt": failureCount + 1]
        if ok {
            Log.info(.display, "built-in display switched", fields)
        } else {
            Log.warning(.display, "built-in display switch failed", fields)
        }

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
            self?.handleWake(source: "system wake")
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake(source: "screens wake")
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake(source: "session active")
        }

        // تغییر آرایش مانیتورها (وصل/قطع شدن، تغییر رزولوشن)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logDisplays("screen parameters changed")
            self?.noteActiveDisplayChange()
            self?.isSleeping = false
            self?.resetFailureState()
            // The reconcile loop is stopped while paused, so this is the only
            // thing watching for the change that ends a display pause.
            self?.checkPause()
            self?.edidCache.removeAll()
            self?.scheduleReconcile(after: 2.0)
            // A display that was just attached or woke up comes back at
            // whatever rate macOS chose; this is the one notification that
            // fires for that whether or not switching is on.
            self?.scheduleRefreshRateEnforcement(after: 2.5)
            // Unplugging the last monitor has to bring sleep back now, not on
            // the next timer tick: the lid may already be closed.
            self?.updateLidAwake()
            self?.scheduleUISizeMatch()
            self?.scheduleDesktopPictureChecksAfterLayoutChange()
        }
    }

    /// Called on every screen change, including the ones in between two size
    /// passes that the debounce would otherwise hide.
    func noteActiveDisplayChange() {
        let keys = Set(DesktopPicture.activeDisplays().map(displayKey))
        if keys != lastActiveDisplayKeys {
            lastActiveDisplayKeys = keys
            activeDisplaysChangedSinceUISizeMatch = true
        }
    }

    /// A closed lid takes the built-in panel off the online list. Switching it
    /// on then fails (CGSConfigureDisplayEnabled 1001), and macOS brings it
    /// back by itself when the lid opens.
    func internalPanelOnline() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    @objc func handleSleep() {
        Log.info(.lifecycle, "system will sleep", ["enabled": isEnabled])
        isSleeping = true
        reconcileWorkItem?.cancel()
        guard isEnabled else { return }
        lastKnownInternalActive = nil
        guard internalPanelOnline() else { return }
        // قبل از خواب سیستم، مانیتور داخلی را روشن می‌کنیم تا مک‌اواس با حالت عادی بخوابد
        _ = setInternalEnabled(true)
    }

    func handleWake(source: String) {
        Log.info(.lifecycle, "woke", ["source": source])
        isSleeping = false
        // Displays come back from sleep at whatever rate they like, so a wake
        // counts as every display appearing again.
        refreshRatePresentKeys.removeAll()
        resetFailureState()
        // شناسه‌ی مانیتور داخلی بعد از بیداری عوض شده؛ کش را دور می‌ریزیم
        internalDisplayID = 0
        lastKnownInternalActive = nil
        resolveInternalDisplay()
        // چند بار در بازه‌های مختلف بررسی می‌کنیم چون مانیتور خارجی ممکن است دیرتر برگردد
        scheduleReconcile(after: 4.0)
        updateLidAwake()
        scheduleUISizeMatch(after: 6)
        scheduleDesktopPictureCheck(after: 8)
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
    // Only the flags that mean a display came, went or switched; mode and
    // origin changes arrive in bursts and the screen-parameters line covers them.
    let named: [(CGDisplayChangeSummaryFlags, String)] = [(.addFlag, "added"), (.removeFlag, "removed"),
                                                          (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
                                                          (.mirrorFlag, "mirrored"), (.unMirrorFlag, "unmirrored")]
    let changes = named.filter { flags.contains($0.0) }.map { $0.1 }
    if !changes.isEmpty {
        Log.info(.display, "display reconfigured",
                 ["display": display, "builtin": CGDisplayIsBuiltin(display) != 0, "changes": changes])
    }
    DispatchQueue.main.async {
        // A monitor unplugged and back before the next pass still counts
        // as appearing.
        if flags.contains(.addFlag) {
            monitor.refreshRatePresentKeys.remove(monitor.displayKey(display))
        }
        monitor.isSleeping = false
        monitor.internalDisplayID = 0 // شناسه ممکن است عوض شده باشد
        monitor.edidCache.removeAll()
        monitor.resetFailureState()
        monitor.scheduleReconcile(after: 2.0)
        monitor.scheduleDesktopPictureCheck()
    }
}

// Runs on the main run loop, where the source was added.
let powerSourceCallback: IOPowerSourceCallbackType = { context in
    guard let context = context else { return }
    Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().updateLidAwake()
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
        isMenuOpen = true
        refreshMenu()
        refreshNotificationAuthorization()
        startMenuRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        stopMenuRefreshTimer()
        if uiSizeStepChanged {
            uiSizeStepChanged = false
            // Moving the slider asks for every display to follow it again.
            uiSizeManual.removeAll()
            scheduleUISizeMatch(after: 0.3, force: true)
        }
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
