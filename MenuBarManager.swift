//
//  MenuBarManager.swift
//  Wand
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

/// Shared localization shorthand — used across the menu bar, panel, and model names.
func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

struct LearnedShortcut: Codable, Equatable {
    let keyCode: UInt16
    let flagsRawValue: UInt64
    let label: String

    var cgFlags: CGEventFlags { CGEventFlags(rawValue: flagsRawValue) }
}

enum TextActionSuffix: String, Codable { case none, space, enter }
struct TextActionSpec: Codable, Equatable { let text: String; let suffix: TextActionSuffix }

/// Everything an input can trigger, grouped into three families the panel shows as submenus:
/// function keys, F-keys, and combos — plus the data-backed special actions. The case name is
/// the persisted rawValue (terse, stable); pre-reorg saved strings migrate via `parse`.
/// `learnedShortcut` / `customText` / `openApp` are placeholders whose data lives in a side
/// table keyed by `MappingTarget.storageKey`, so they only appear once configured.
enum RemoteAction: String, CaseIterable {
    // 第 1 类 · 单一功能键
    case enter, tab, space, backspace, delete
    case esc, up, down, left, right
    case leftCtrl, rightCtrl, leftCmd, rightCmd, leftOpt, rightOpt, leftShift, rightShift, fn
    case leftClick, rightClick
    case cursorUp, cursorDown, cursorLeft, cursorRight   // nudge the mouse cursor（方向环默认动作）
    // 第 2 类 · F 键
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    // 第 3 类 · 组合键（learnedShortcut = 自定义组合，兜底）
    case cmdC, cmdV, cmdX, cmdZ, cmdShiftZ, cmdA, cmdS, cmdW, cmdF, ctrlC, shiftTab
    case learnedShortcut
    // 特殊功能
    case customText, openApp, none

    enum Category { case functionKey, fKey, combo, special }

    var category: Category {
        switch self {
        case .enter, .tab, .space, .backspace, .delete, .esc, .up, .down, .left, .right,
             .leftCtrl, .rightCtrl, .leftCmd, .rightCmd, .leftOpt, .rightOpt, .leftShift, .rightShift, .fn,
             .leftClick, .rightClick, .cursorUp, .cursorDown, .cursorLeft, .cursorRight:
            return .functionKey
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return .fKey
        case .cmdC, .cmdV, .cmdX, .cmdZ, .cmdShiftZ, .cmdA, .cmdS, .cmdW, .cmdF, .ctrlC, .shiftTab, .learnedShortcut:
            return .combo
        case .customText, .openApp, .none:
            return .special
        }
    }

    var displayTitle: String {
        switch self {
        case .enter: return "Enter"
        case .tab: return "Tab"
        case .space: return "Space"
        case .backspace: return "Backspace"
        case .delete: return "Delete"
        case .esc: return "Esc"
        case .up: return tr("action.up")
        case .down: return tr("action.down")
        case .left: return tr("action.left")
        case .right: return tr("action.right")
        case .leftCtrl: return tr("action.leftCtrl")
        case .rightCtrl: return tr("action.rightCtrl")
        case .leftCmd: return tr("action.leftCmd")
        case .rightCmd: return tr("action.rightCmd")
        case .leftOpt: return tr("action.leftOpt")
        case .rightOpt: return tr("action.rightOpt")
        case .leftShift: return tr("action.leftShift")
        case .rightShift: return tr("action.rightShift")
        case .fn: return "Fn"
        case .leftClick: return tr("action.leftClick")
        case .rightClick: return tr("action.rightClick")
        case .cursorUp: return tr("action.cursorUp")
        case .cursorDown: return tr("action.cursorDown")
        case .cursorLeft: return tr("action.cursorLeft")
        case .cursorRight: return tr("action.cursorRight")
        case .f1: return "F1"; case .f2: return "F2"; case .f3: return "F3"; case .f4: return "F4"
        case .f5: return "F5"; case .f6: return "F6"; case .f7: return "F7"; case .f8: return "F8"
        case .f9: return "F9"; case .f10: return "F10"; case .f11: return "F11"; case .f12: return "F12"
        case .cmdC: return "Cmd+C"
        case .cmdV: return "Cmd+V"
        case .cmdX: return "Cmd+X"
        case .cmdZ: return "Cmd+Z"
        case .cmdShiftZ: return "Cmd+Shift+Z"
        case .cmdA: return "Cmd+A"
        case .cmdS: return "Cmd+S"
        case .cmdW: return "Cmd+W"
        case .cmdF: return "Cmd+F"
        case .ctrlC: return "Ctrl+C"
        case .shiftTab: return "Shift+Tab"
        case .learnedShortcut: return tr("action.learnedShortcut")
        case .customText: return tr("action.customText")
        case .openApp: return tr("action.openApp")
        case .none: return tr("action.none")
        }
    }

    /// Parse a persisted rawValue, migrating the pre-reorg strings (buttons, swipes, double-clicks).
    /// Removed actions (slash commands, Open Remote Panel) map to nil so they simply drop out.
    static func parse(_ raw: String) -> RemoteAction? {
        RemoteAction(rawValue: raw) ?? legacyMap[raw]
    }

    private static let legacyMap: [String: RemoteAction] = [
        "Enter: Submit prompt": .enter,
        "Tab: Autocomplete / Accept suggestion": .tab,
        "Up: Navigate Up": .up,
        "Down: Navigate Down": .down,
        "Left: Navigate Left": .left,
        "Right: Navigate Right": .right,
        "Esc: Navigate Back": .esc,
        "Control + C: Cancel Prompt": .ctrlC,
        "Mode Switching (Shift + Tab)": .shiftTab,
        "Space: Claude Voice Dictation": .space,
        "Fn: WeChat / 3rd-party Voice Input": .fn,
        "Left Control": .leftCtrl,
        "Right Control": .rightCtrl,
        "Left Command": .leftCmd,
        "Right Command: 3rd-party Voice Dictation": .rightCmd,
        "Left Shift": .leftShift,
        "Right Shift": .rightShift,
        "Right Option: 3rd-party Voice Dictation": .rightOpt,
        "Learned Keyboard Shortcut": .learnedShortcut,
        "Custom Text or Command": .customText,
        "Mouse Click": .leftClick,
        "None": .none,
    ]
}

/// An input a mapping can be bound to. `storageKey` indexes the side tables that hold the
/// data for `learnedShortcut` / `customText` / `openApp`; the string form is what the HID
/// path already passes around, so both binding kinds share one namespace.
enum MappingTarget: Hashable {
    case button(String)
    case doubleClick(String)

    var storageKey: String {
        switch self {
        case .button(let key):      return key
        case .doubleClick(let key): return "double:\(key)"
        }
    }
}

/// Discovers installed .app bundles to populate the panel's app picker.
enum InstalledApps {
    struct App {
        let name: String
        let bundleID: String
    }

    private static let searchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// Scanning touches the disk and reads every Info.plist, so scan once per process.
    private static var cache: [App]?

    static func all() -> [App] {
        if let cache { return cache }
        var seen = Set<String>()
        var apps: [App] = []
        for root in searchRoots {
            for url in bundles(in: root) {
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                apps.append(App(name: FileManager.default.displayName(atPath: url.path), bundleID: id))
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = apps
        return apps
    }

    /// Resolve a bundle ID to a display name, falling back to a live lookup for apps outside
    /// the scanned roots, then to the bare identifier if it isn't installed at all.
    static func displayName(forBundleID id: String) -> String {
        if let app = all().first(where: { $0.bundleID == id }) { return app.name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// One level deep: picks up /Applications/Utilities/* without descending into app bundles.
    private static func bundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                result.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let nested = (try? fm.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                result.append(contentsOf: nested.filter { $0.pathExtension == "app" })
            }
        }
        return result
    }
}

// Scroll speed options
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"
    
    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }
}

class MenuBarManager {
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private var remotePanelController: RemotePanelController?
    private(set) var isConnected = false
    private(set) var remoteModel: AppleRemoteModel = .unknown
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: RemoteAction] = [:]
    private var doubleClickMappings: [String: RemoteAction] = [:]

    // Side tables for the data-backed actions, all keyed by MappingTarget.storageKey.
    private var learnedShortcuts: [String: LearnedShortcut] = [:]
    private var textActions: [String: TextActionSpec] = [:]
    private var appActions: [String: String] = [:]   // storageKey -> bundle identifier

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Shared cursor state (owned by the app delegate) so cursor-nudge actions stay consistent
    /// with the trackpad path — same clamping, same multi-display handling.
    weak var cursorController: CursorController?

    /// How far each trackpad direction click nudges the cursor. User-tunable via the panel slider.
    private(set) var dpadStep: CGFloat = 20

    func setDpadStep(_ value: CGFloat) {
        dpadStep = max(5, min(80, value))
        UserDefaults.standard.set(Double(dpadStep), forKey: "dpadStep")
    }

    /// Whether a light tap (no physical press) on the trackpad triggers a click. User-tunable.
    private(set) var tapToClickEnabled: Bool = true

    func setTapToClickEnabled(_ enabled: Bool) {
        tapToClickEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "tapToClickEnabled")
    }

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: tr("status.disconnected"), action: nil, keyEquivalent: "")

        migrateFromLegacyDomain()
        loadMappings()
        loadLearnedShortcuts()
        loadDoubleClickMappings()
        loadTextActions()
        loadAppActions()
        // Swipe-to-action was removed (gliding is purely cursor movement now) — drop the
        // stale persisted mappings so they don't linger in the prefs domain.
        UserDefaults.standard.removeObject(forKey: "swipeMappings")
        if UserDefaults.standard.object(forKey: "dpadStep") != nil {
            dpadStep = CGFloat(UserDefaults.standard.double(forKey: "dpadStep"))
        }
        if UserDefaults.standard.object(forKey: "tapToClickEnabled") != nil {
            tapToClickEnabled = UserDefaults.standard.bool(forKey: "tapToClickEnabled")
        }
        setupMenuBar()
    }
    
    /// One-time carry-over from the app's previous bundle id (com.mavrick.app) after the rename
    /// to Wand (com.wand.app). UserDefaults is keyed by bundle id, so without this the rename
    /// would look like a fresh install and drop every saved mapping.
    ///
    /// Gated by a dedicated sentinel key, NOT a business key: loadMappings() writes
    /// "buttonMappings" back on every launch, so using it as the sentinel would mark migration
    /// "done" after the first launch even when other keys were never copied. Copies per-key
    /// (only keys the new domain doesn't have yet), so a partially-migrated install gets its
    /// remaining keys backfilled on the next launch without overwriting anything newer.
    private func migrateFromLegacyDomain() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: "legacyDomainMigrated"),
              let legacy = UserDefaults(suiteName: "com.mavrick.app") else { return }
        let keys = ["buttonMappings", "doubleClickMappings",
                    "learnedShortcuts", "textActions", "appActions",
                    "dpadStep", "tapToClickEnabled"]
        var copied: [String] = []
        for key in keys where current.object(forKey: key) == nil && legacy.object(forKey: key) != nil {
            current.set(legacy.object(forKey: key), forKey: key)
            copied.append(key)
        }
        current.set(true, forKey: "legacyDomainMigrated")
        if !copied.isEmpty { rmDebug("🔀 已从旧 bundle id com.mavrick.app 迁移: \(copied.joined(separator: ", "))") }
    }

    private func loadMappings() {
        let defaultMappings: [String: RemoteAction] = [
            "playPause": .enter,
            "menu": .esc,
            "select": .leftClick,
            "volumeUp": .up,
            "volumeDown": .down,
            "siri": .space,
            "tv": .ctrlC,
            "power": .none,
            "mute": .none,
            // 方向环点击默认平移光标；在面板里可改绑任意动作
            "dpadUp": .cursorUp,
            "dpadDown": .cursorDown,
            "dpadLeft": .cursorLeft,
            "dpadRight": .cursorRight
        ]

        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            // parse migrates pre-reorg rawValues; unrecognized (removed) actions drop out.
            for (button, actionRaw) in saved {
                if let action = RemoteAction.parse(actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings where buttonMappings[button] == nil {
                buttonMappings[button] = action
            }
            // "select" is hard-wired to click/drag in the HID handler and locked in the panel;
            // any other persisted value (e.g. a pre-reorg default that was never effective)
            // is dead data — normalize so storage matches actual behavior.
            buttonMappings["select"] = .leftClick
            saveMappings()   // persist the migrated rawValues in the new form
        } else {
            buttonMappings = defaultMappings
            saveMappings()
        }
    }
    
    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
    }

    private func loadLearnedShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: "learnedShortcuts"),
              let decoded = try? JSONDecoder().decode([String: LearnedShortcut].self, from: data) else { return }
        learnedShortcuts = decoded
    }

    private func saveLearnedShortcuts() {
        guard let data = try? JSONEncoder().encode(learnedShortcuts) else { return }
        UserDefaults.standard.set(data, forKey: "learnedShortcuts")
    }

    private func loadDoubleClickMappings() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "doubleClickMappings") as? [String: String] else { return }
        for (button, raw) in saved { if let action = RemoteAction.parse(raw) { doubleClickMappings[button] = action } }
        saveDoubleClickMappings()   // converge migrated rawValues to the new form
    }

    private func saveDoubleClickMappings() {
        UserDefaults.standard.set(doubleClickMappings.mapValues(\.rawValue), forKey: "doubleClickMappings")
    }

    private func loadTextActions() {
        guard let data = UserDefaults.standard.data(forKey: "textActions"),
              let decoded = try? JSONDecoder().decode([String: TextActionSpec].self, from: data) else { return }
        textActions = decoded
    }
    private func saveTextActions() {
        if let data = try? JSONEncoder().encode(textActions) { UserDefaults.standard.set(data, forKey: "textActions") }
    }

    private func loadAppActions() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "appActions") as? [String: String] else { return }
        appActions = saved
    }
    private func saveAppActions() {
        UserDefaults.standard.set(appActions, forKey: "appActions")
    }
    
    /// Procedurally draw the menu-bar icon — a Siri Remote silhouette: a tall rounded body
    /// with the trackpad punched out as a circle near the top (even-odd fill). Rendered as a
    /// template image so macOS tints it to match the menu bar in light/dark mode.
    private static func makeRemoteIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            // Remote body: a slim, tall rounded bar.
            let body = CGRect(x: 0.34 * s, y: 0.10 * s, width: 0.32 * s, height: 0.80 * s)
            // Trackpad: a circle cut out near the top (y is small = top in this flipped context).
            let padR: CGFloat = 0.11 * s
            let trackpad = CGRect(x: 0.50 * s - padR, y: 0.30 * s - padR,
                                  width: 2 * padR, height: 2 * padR)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: body, cornerWidth: 0.16 * s, cornerHeight: 0.16 * s, transform: nil))
            path.addEllipse(in: trackpad)

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }
        
        button.image = Self.makeRemoteIcon()
        button.title = ""
        
        rebuildMenu()
        statusItem.menu = menu
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: tr("menu.title"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())

        let panelItem = NSMenuItem(title: tr("menu.openPanel"), action: #selector(openRemotePanel), keyEquivalent: ",")
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: tr("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func openRemotePanel() {
        showRemotePanel()
    }

    func showRemotePanel() {
        if remotePanelController == nil {
            remotePanelController = RemotePanelController(manager: self)
        }
        // This is an accessory app (no Dock icon), so its windows don't come forward on their
        // own — a pinch fired while another app is active would open the panel behind it.
        NSApp.activate(ignoringOtherApps: true)
        remotePanelController?.showWindow(nil)
        remotePanelController?.window?.makeKeyAndOrderFront(nil)
    }

    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = connected
            self.statusMenuItem.title = connected ? tr("status.connected") : tr("status.disconnected")
            self.statusItem.button?.appearsDisabled = !connected
            self.remotePanelController?.updateConnectionStatus(connected)
        }
    }

    func updateRemoteModel(_ model: AppleRemoteModel) {
        remoteModel = model
        remotePanelController?.updateRemoteModel(model)
    }

    // MARK: - Mappings

    func mapping(for target: MappingTarget) -> RemoteAction {
        switch target {
        case .button(let key):      return buttonMappings[key] ?? .none
        case .doubleClick(let key): return doubleClickMappings[key] ?? .none
        }
    }

    func setMapping(_ action: RemoteAction, for target: MappingTarget) {
        switch target {
        case .button(let key):      buttonMappings[key] = action;      saveMappings()
        case .doubleClick(let key): doubleClickMappings[key] = action; saveDoubleClickMappings()
        }
        rebuildMenu()
    }

    /// The actions offered for one input. Every input gets the full list; the data-backed
    /// placeholders only appear once their data (shortcut / text / app) has been configured.
    func availableActions(for target: MappingTarget) -> [RemoteAction] {
        let key = target.storageKey
        return RemoteAction.allCases.filter { action in
            switch action {
            case .learnedShortcut: return learnedShortcuts[key] != nil
            case .customText:      return textActions[key] != nil
            case .openApp:         return appActions[key] != nil
            default:               return true
            }
        }
    }

    // MARK: - Data-backed actions

    func learnedShortcut(for target: MappingTarget) -> LearnedShortcut? { learnedShortcuts[target.storageKey] }

    func setLearnedShortcut(_ shortcut: LearnedShortcut, for target: MappingTarget) {
        learnedShortcuts[target.storageKey] = shortcut
        saveLearnedShortcuts()
        setMapping(.learnedShortcut, for: target)
    }

    func textAction(for target: MappingTarget) -> TextActionSpec? { textActions[target.storageKey] }

    func setTextAction(_ spec: TextActionSpec, for target: MappingTarget) {
        textActions[target.storageKey] = spec
        saveTextActions()
        setMapping(.customText, for: target)
    }

    func appAction(for target: MappingTarget) -> String? { appActions[target.storageKey] }

    func setAppAction(bundleID: String, for target: MappingTarget) {
        appActions[target.storageKey] = bundleID
        saveAppActions()
        setMapping(.openApp, for: target)
    }

    /// Title for a data-backed action, showing what it's actually bound to rather than the
    /// generic case name. Falls back to the generic title when nothing is configured yet.
    func displayTitle(for action: RemoteAction, target: MappingTarget) -> String {
        switch action {
        case .learnedShortcut:
            return learnedShortcut(for: target)?.label ?? action.displayTitle
        case .customText:
            return textAction(for: target)?.text ?? action.displayTitle
        case .openApp:
            guard let id = appAction(for: target) else { return action.displayTitle }
            return String(format: tr("button.action.openApp.named"), InstalledApps.displayName(forBundleID: id))
        default:
            return action.displayTitle
        }
    }

    func resetMappingsToDefaults() {
        buttonMappings = [
            "playPause": .enter, "menu": .esc, "select": .leftClick,
            "volumeUp": .up, "volumeDown": .down, "siri": .space,
            "tv": .ctrlC, "power": .none, "mute": .none,
            "dpadUp": .cursorUp, "dpadDown": .cursorDown,
            "dpadLeft": .cursorLeft, "dpadRight": .cursorRight
        ]
        // Also clear double-click bindings and every side table, or stale learned shortcuts /
        // text / app bindings would survive a "reset to defaults".
        doubleClickMappings = [:]
        learnedShortcuts = [:]
        textActions = [:]
        appActions = [:]
        // Tunables are part of "defaults" too — reset them and their persisted values.
        dpadStep = 20
        tapToClickEnabled = true
        UserDefaults.standard.removeObject(forKey: "dpadStep")
        UserDefaults.standard.removeObject(forKey: "tapToClickEnabled")
        saveMappings()
        saveDoubleClickMappings()
        saveLearnedShortcuts()
        saveTextActions()
        saveAppActions()
        rebuildMenu()
    }

    func getMapping(for button: String) -> RemoteAction {
        return buttonMappings[button] ?? .none
    }

    func getDoubleClickMapping(for button: String) -> RemoteAction { doubleClickMappings[button] ?? .none }

    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
    private func typeString(_ s: String) {
        let utf16 = Array(s.utf16)
        let count = utf16.count
        guard count > 0 else { return }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            down?.post(tap: .cghidEventTap)
            usleep(5000)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
    }

    func executeTextAction(for key: String) {
        guard let spec = textActions[key] else { return }
        typeString(spec.text + (spec.suffix == .space ? " " : ""))
        if spec.suffix == .enter { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.sendKey(kVK_Return) } }
    }

    /// Launch the app bound to this input, or bring it to the front if it's already running.
    func executeAppAction(for key: String) {
        guard let bundleID = appActions[key] else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            rmDebug("⚠️ Open App: nothing installed for bundle id \(bundleID)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error { rmDebug("⚠️ Open App failed for \(bundleID): \(error.localizedDescription)") }
        }
    }

    /// Execute a mapped action. `storageKey` resolves the data-backed actions — it's
    /// `MappingTarget.storageKey`, which the HID path already passes as its button name.
    /// Everything fires as a single tap; there is no press-and-hold anymore.
    func execute(_ action: RemoteAction, storageKey: String) {
        switch action {
        case .none:      break
        // 第 1 类 · 功能键
        case .enter:     sendKey(kVK_Return)
        case .tab:       sendKey(kVK_Tab)
        case .space:     sendKey(kVK_Space)
        case .backspace: sendKey(kVK_Delete)         // 退格删除
        case .delete:    sendKey(kVK_ForwardDelete)  // 向前删除
        case .esc:       sendKey(kVK_Escape)
        case .up:        sendKey(kVK_UpArrow)
        case .down:      sendKey(kVK_DownArrow)
        case .left:      sendKey(kVK_LeftArrow)
        case .right:     sendKey(kVK_RightArrow)
        case .leftCtrl:  sendModifierTap(kVK_Control,      flag: .maskControl)
        case .rightCtrl: sendModifierTap(kVK_RightControl, flag: .maskControl)
        case .leftCmd:   sendModifierTap(kVK_Command,      flag: .maskCommand)
        case .rightCmd:  sendModifierTap(kVK_RightCommand, flag: .maskCommand)
        case .leftOpt:   sendModifierTap(kVK_Option,       flag: .maskAlternate)
        case .rightOpt:  sendModifierTap(kVK_RightOption,  flag: .maskAlternate)
        case .leftShift: sendModifierTap(kVK_Shift,        flag: .maskShift)
        case .rightShift: sendModifierTap(kVK_RightShift,  flag: .maskShift)
        case .fn:        sendFnKeyTap()
        case .leftClick: performClick()
        case .rightClick: performRightClick()
        case .cursorUp:    cursorController?.moveCursor(deltaX: 0, deltaY: -dpadStep)
        case .cursorDown:  cursorController?.moveCursor(deltaX: 0, deltaY: dpadStep)
        case .cursorLeft:  cursorController?.moveCursor(deltaX: -dpadStep, deltaY: 0)
        case .cursorRight: cursorController?.moveCursor(deltaX: dpadStep, deltaY: 0)
        // 第 2 类 · F 键
        case .f1:  sendKey(kVK_F1);  case .f2:  sendKey(kVK_F2);  case .f3:  sendKey(kVK_F3)
        case .f4:  sendKey(kVK_F4);  case .f5:  sendKey(kVK_F5);  case .f6:  sendKey(kVK_F6)
        case .f7:  sendKey(kVK_F7);  case .f8:  sendKey(kVK_F8);  case .f9:  sendKey(kVK_F9)
        case .f10: sendKey(kVK_F10); case .f11: sendKey(kVK_F11); case .f12: sendKey(kVK_F12)
        // 第 3 类 · 组合键
        case .cmdC:      sendKey(kVK_ANSI_C, flags: .maskCommand)
        case .cmdV:      sendKey(kVK_ANSI_V, flags: .maskCommand)
        case .cmdX:      sendKey(kVK_ANSI_X, flags: .maskCommand)
        case .cmdZ:      sendKey(kVK_ANSI_Z, flags: .maskCommand)
        case .cmdShiftZ: sendKey(kVK_ANSI_Z, flags: [.maskCommand, .maskShift])
        case .cmdA:      sendKey(kVK_ANSI_A, flags: .maskCommand)
        case .cmdS:      sendKey(kVK_ANSI_S, flags: .maskCommand)
        case .cmdW:      sendKey(kVK_ANSI_W, flags: .maskCommand)
        case .cmdF:      sendKey(kVK_ANSI_F, flags: .maskCommand)
        case .ctrlC:     sendKey(kVK_ANSI_C, flags: .maskControl)
        case .shiftTab:  sendKey(kVK_Tab, flags: .maskShift)
        case .learnedShortcut:
            guard let shortcut = learnedShortcuts[storageKey] else { break }
            // Fn is a modifier, not a regular key — keyDown/keyUp for kVK_Function is silently
            // ignored by most apps, so a learned "Fn alone" must go through flagsChanged.
            if Int(shortcut.keyCode) == kVK_Function && shortcut.cgFlags.subtracting(.maskSecondaryFn).isEmpty {
                sendFnKeyTap()
            } else {
                sendKey(Int(shortcut.keyCode), flags: shortcut.cgFlags)
            }
        // 特殊功能
        case .customText: executeTextAction(for: storageKey)
        case .openApp:    executeAppAction(for: storageKey)
        }
    }

    // Cursor position comes from CGEvent(source:nil) — already in Quartz coordinates, so no
    // Cocoa→Quartz flip is needed. Flipping via NSScreen.main is wrong on multi-display setups:
    // NSScreen.main is the key window's screen, not the Quartz-origin primary display.
    private func performClick() {
        let cgPos = CGEvent(source: nil)?.location ?? .zero

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    private func performRightClick() {
        let cgPos = CGEvent(source: nil)?.location ?? .zero

        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: cgPos, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: cgPos, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    /// Tap a modifier key alone (e.g. Right Command) — used to trigger push-to-talk dictation.
    private func sendModifierTap(_ keyCode: Int, flag: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flag
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }

    /// Tap the Fn/Globe key via flagsChanged events (macOS treats Fn as a modifier,
    /// not a regular key, so keyDown/keyUp for kVK_Function is silently ignored).
    private func sendFnKeyTap() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(source: src) {
            down.type = .flagsChanged
            down.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
            down.flags = .maskSecondaryFn
            down.post(tap: .cghidEventTap)
        }
        usleep(10000)
        if let up = CGEvent(source: src) {
            up.type = .flagsChanged
            up.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }
    
    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}
