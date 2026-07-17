//
//  MenuBarManager.swift
//  Mavrick
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

private func tr(_ key: String) -> String {
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

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable {
    case enterKey = "Enter: Submit prompt"
    case tabKey = "Tab: Autocomplete / Accept suggestion"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case fnKey = "Fn: WeChat / 3rd-party Voice Input"
    case leftCtrl = "Left Control"
    case rightCtrl = "Right Control"
    case leftCmd = "Left Command"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case leftShift = "Left Shift"
    case rightShift = "Right Shift"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case customShortcut = "Learned Keyboard Shortcut"
    case customText = "Custom Text or Command"
    case trackpadClick = "Mouse Click"
    case none = "None"

    var displayTitle: String { tr("button.action.\(String(describing: self))") }

    /// Push-to-talk dictation needs the virtual key held for the full press duration.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// only offered for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .spaceKey, .fnKey, .leftCtrl, .rightCtrl, .leftCmd, .rightCmd,
             .leftShift, .rightShift, .rightOpt: return true
        default: return false
        }
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0) — verified via /tmp/mavrick.log.
/// menu/tv/select are excluded: menu/tv are press-only on the Siri Remote, select is handled separately for click/drag.
let holdCapableButtons: Set<String> = [
    "playPause", "volumeUp", "volumeDown", "siri",
    "menu", "tv", "mute", "power"
]

/// Trackpad swipe directions (single-finger flicks). Detection happens in TouchHandler;
/// execution is dispatched here so mappings live alongside button mappings.
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// Action a swipe can trigger. Slash-command cases type the raw value (without Enter — user
/// presses Enter themselves). `leftArrow`/`rightArrow` send virtual arrow keys instead of text.
/// `init` is a Swift keyword so the case name is backtick-escaped; rawValue "/init" is what displays.
enum SwipeAction: String, CaseIterable {
    // Priority order: direction-matched arrow (filtered per submenu), then Mode Switching,
    // then ultrathink, then slash commands alphabetically, None last.
    case leftArrow     = "Left: Navigate Left"
    case rightArrow    = "Right: Navigate Right"
    case modeSwitch    = "Mode Switching (Shift + Tab)"
    case ultrathink    = "ultrathink"
    case btw           = "/btw"
    case compact       = "/compact"
    case config        = "/config"
    case context       = "/context"
    case effort        = "/effort"
    case `init`        = "/init"
    case model         = "/model"
    case remoteControl = "/remote-control"
    case schedule      = "/schedule"
    case tasks         = "/tasks"
    case usage         = "/usage"
    case none          = "None"

    var displayTitle: String {
        switch self {
        case .ultrathink, .btw, .compact, .config, .context, .effort, .`init`,
             .model, .remoteControl, .schedule, .tasks, .usage:
            return rawValue
        default:
            return tr("swipe.action.\(String(describing: self))")
        }
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
    private var buttonMappings: [String: ButtonAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: SwipeAction] = [:]
    private var learnedShortcuts: [String: LearnedShortcut] = [:]
    private var doubleClickMappings: [String: ButtonAction] = [:]
    private var textActions: [String: TextActionSpec] = [:]

    private static let defaultSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .usage,
        .down:  .compact,
        .left:  .model,
        .right: .modeSwitch,
    ]

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: tr("status.disconnected"), action: nil, keyEquivalent: "")
        
        loadMappings()
        loadLearnedShortcuts()
        loadDoubleClickMappings()
        loadTextActions()
        loadSwipeMappings()
        setupMenuBar()
    }
    
    private func loadMappings() {
        // Default mappings (only used on first launch / after schema upgrade)
        let defaultMappings: [String: ButtonAction] = [
            "playPause": .enterKey,
            "menu": .escKey,
            "select": .trackpadClick,
            "volumeUp": .upKey,
            "volumeDown": .downKey,
            "siri": .spaceKey,
            "tv": .ctrlC,
            "power": .none,
            "mute": .none
        ]

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        let currentSchema = 4
        let savedSchema = UserDefaults.standard.integer(forKey: "buttonMappingsSchema")
        if savedSchema < 3 {
            UserDefaults.standard.removeObject(forKey: "buttonMappings")
        } else if savedSchema < 4 {
            // Targeted migration: reset "select" so the new default applies, preserve others.
            if var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
                saved.removeValue(forKey: "select")
                UserDefaults.standard.set(saved, forKey: "buttonMappings")
            }
        }
        if savedSchema < currentSchema {
            UserDefaults.standard.set(currentSchema, forKey: "buttonMappingsSchema")
        }

        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            for (button, actionRaw) in saved {
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings where action.requiresHold && !holdCapableButtons.contains(button) {
                buttonMappings[button] = ButtonAction.none
            }
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
        for (button, raw) in saved { if let action = ButtonAction(rawValue: raw) { doubleClickMappings[button] = action } }
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
    
    /// Procedurally draw the menu-bar icon — a walkie-talkie glyph mirroring the
    /// Figma reference (36-unit viewBox: antenna + body with display + speaker
    /// holes via even-odd fill). 2× centered scale matches the menu-bar reading
    /// size; overflow clips at the canvas edges by design.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: -s / 2, y: -s / 2)

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            let antenna = CGRect(x: 0.5260 * s, y: 0.1944 * s,
                                 width: 0.0638 * s, height: 0.1594 * s)
            let body    = CGRect(x: 0.3348 * s, y: 0.3538 * s,
                                 width: 0.3187 * s, height: 0.4462 * s)
            let display = CGRect(x: 0.3986 * s, y: 0.6406 * s,
                                 width: 0.1911 * s, height: 0.0956 * s)
            let speakerR: CGFloat = 0.0956 * s
            let speaker = CGRect(x: 0.4942 * s - speakerR, y: 0.5131 * s - speakerR,
                                 width: 2 * speakerR, height: 2 * speakerR)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: antenna,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addPath(CGPath(roundedRect: body,
                                cornerWidth: 0.0556 * s, cornerHeight: 0.0556 * s, transform: nil))
            path.addPath(CGPath(roundedRect: display,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addEllipse(in: speaker)

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
        
        button.image = Self.makeWaveIcon()
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

        let panelItem = NSMenuItem(title: "打开遥控器面板…", action: #selector(openRemotePanel), keyEquivalent: ",")
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: tr("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func changeMapping(_ sender: NSMenuItem) {
        guard let (buttonKey, action) = sender.representedObject as? (String, ButtonAction) else {
            return
        }
        buttonMappings[buttonKey] = action
        saveMappings()
        rebuildMenu()
    }

    @objc private func openRemotePanel() {
        showRemotePanel()
    }

    func showRemotePanel() {
        if remotePanelController == nil {
            remotePanelController = RemotePanelController(manager: self)
        }
        remotePanelController?.showWindow(nil)
    }

    @objc private func changeSwipeMapping(_ sender: NSMenuItem) {
        guard let (direction, action) = sender.representedObject as? (SwipeDirection, SwipeAction) else {
            return
        }
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
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

    func setMapping(_ action: ButtonAction, for button: String) {
        buttonMappings[button] = action
        saveMappings()
        rebuildMenu()
    }

    func availableActions(for button: String) -> [ButtonAction] {
        ButtonAction.allCases.filter { action in
            (!action.requiresHold || holdCapableButtons.contains(button)) &&
            (action != .trackpadClick || button == "select") &&
            (action != .customShortcut || learnedShortcuts[button] != nil) &&
            (action != .customText || textActions[button] != nil)
        }
    }

    func learnedShortcut(for button: String) -> LearnedShortcut? { learnedShortcuts[button] }

    func setLearnedShortcut(_ shortcut: LearnedShortcut, for button: String) {
        learnedShortcuts[button] = shortcut
        buttonMappings[button] = .customShortcut
        saveLearnedShortcuts()
        saveMappings()
        rebuildMenu()
    }

    func getDoubleClickMapping(for button: String) -> ButtonAction { doubleClickMappings[button] ?? .none }

    func setDoubleClickMapping(_ action: ButtonAction, for button: String) {
        doubleClickMappings[button] = action
        saveDoubleClickMappings()
    }

    func setLearnedDoubleClickShortcut(_ shortcut: LearnedShortcut, for button: String) {
        learnedShortcuts["double:\(button)"] = shortcut
        doubleClickMappings[button] = .customShortcut
        saveLearnedShortcuts()
        saveDoubleClickMappings()
    }

    func learnedDoubleClickShortcut(for button: String) -> LearnedShortcut? { learnedShortcuts["double:\(button)"] }

    func textAction(for key: String) -> TextActionSpec? { textActions[key] }
    func setTextAction(_ spec: TextActionSpec, for button: String, doubleClick: Bool) {
        let key = doubleClick ? "double:\(button)" : button
        textActions[key] = spec
        if doubleClick { doubleClickMappings[button] = .customText; saveDoubleClickMappings() }
        else { buttonMappings[button] = .customText; saveMappings() }
        saveTextActions()
    }
    func executeTextAction(for key: String) {
        guard let spec = textActions[key] else { return }
        typeString(spec.text + (spec.suffix == .space ? " " : ""))
        if spec.suffix == .enter { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.sendKey(kVK_Return) } }
    }

    func availableDoubleClickActions(for button: String) -> [ButtonAction] {
        ButtonAction.allCases.filter {
            !$0.requiresHold && ($0 != .trackpadClick || button == "select") &&
            ($0 != .customShortcut || learnedDoubleClickShortcut(for: button) != nil)
            && ($0 != .customText || textActions["double:\(button)"] != nil)
        }
    }

    func setSwipeMapping(_ action: SwipeAction, for direction: SwipeDirection) {
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
    }

    func availableSwipeActions(for direction: SwipeDirection) -> [SwipeAction] {
        SwipeAction.allCases.filter {
            ($0 != .leftArrow || direction == .left) &&
            ($0 != .rightArrow || direction == .right)
        }
    }

    func resetMappingsToDefaults() {
        buttonMappings = [
            "playPause": .enterKey, "menu": .escKey, "select": .trackpadClick,
            "volumeUp": .upKey, "volumeDown": .downKey, "siri": .spaceKey,
            "tv": .ctrlC, "power": .none, "mute": .none
        ]
        swipeMappings = Self.defaultSwipeMappings
        saveMappings()
        saveSwipeMappings()
        rebuildMenu()
    }
    
    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
    }
    
    // Map HID codes to button names
    private let hidCodeToButton: [String: String] = [
        "0x000C:0x00CD": "playPause",    // Play/Pause
        "0x000C:0x00B5": "nextTrack",    // Next (not a physical button but for mapping)
        "0x000C:0x00B6": "prevTrack",    // Previous (not a physical button but for mapping)
        "0x000C:0x00E9": "volumeUp",     // Volume Up
        "0x000C:0x00EA": "volumeDown",   // Volume Down
        "0x0001:0x0086": "menu",         // Menu button (System Menu Main)
        "0x000C:0x0080": "select",       // Select button
        "0x000C:0x0040": "menu",         // Menu (alternate)
        "0x000C:0x0223": "menu",         // Home
        "0x000C:0x0224": "back",         // Back
    ]
    
    /// Get the action name for a given HID code (for event interception)
    func getMappingForHIDCode(_ hidCode: String) -> String? {
        guard let buttonName = hidCodeToButton[hidCode],
              let action = buttonMappings[buttonName] else {
            return nil
        }
        return action.rawValue
    }
    
    private func loadSwipeMappings() {
        if let saved = UserDefaults.standard.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (dirRaw, actionRaw) in saved {
                if let dir = SwipeDirection(rawValue: dirRaw),
                   let act = SwipeAction(rawValue: actionRaw) {
                    swipeMappings[dir] = act
                }
            }
        }
        // Fill any missing directions with defaults.
        for (dir, act) in Self.defaultSwipeMappings where swipeMappings[dir] == nil {
            swipeMappings[dir] = act
        }
    }

    private func saveSwipeMappings() {
        var toSave: [String: String] = [:]
        for (dir, act) in swipeMappings {
            toSave[dir.rawValue] = act.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "swipeMappings")
    }

    func getSwipeMapping(for direction: SwipeDirection) -> SwipeAction {
        return swipeMappings[direction] ?? .none
    }

    /// Execute the action bound to a swipe direction. Slash-command actions type text
    /// (no Enter — user presses Enter themselves). Arrow/modifier actions send key events.
    func executeSwipe(_ direction: SwipeDirection) {
        let action = swipeMappings[direction] ?? SwipeAction.none
        switch action {
        case .none:
            break
        case .leftArrow:
            sendKey(kVK_LeftArrow)
        case .rightArrow:
            sendKey(kVK_RightArrow)
        case .modeSwitch:
            sendKey(kVK_Tab, flags: .maskShift)
        case .btw, .schedule, .ultrathink:
            // Trailing space: user typically continues with an argument or prose.
            typeString(action.rawValue + " ")
        case .compact, .config, .context, .effort, .`init`,
             .model, .remoteControl, .tasks, .usage:
            // No trailing space: these commands stand alone or open an interactive picker.
            typeString(action.rawValue)
        }
    }

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

    /// Execute an action by name
    func executeAction(_ actionName: String) {
        guard let action = ButtonAction(rawValue: actionName) else { return }

        switch action {
        case .none:
            break
        case .enterKey:
            sendKey(kVK_Return)
        case .tabKey:
            sendKey(kVK_Tab)
        case .upKey:
            sendKey(kVK_UpArrow)
        case .downKey:
            sendKey(kVK_DownArrow)
        case .escKey:
            sendKey(kVK_Escape)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .spaceKey:
            sendKey(kVK_Space)
        case .fnKey:
            sendFnKeyTap()
        case .rightCmd:
            sendModifierTap(kVK_RightCommand, flag: .maskCommand)
        case .leftCmd:
            sendModifierTap(kVK_Command, flag: .maskCommand)
        case .leftCtrl:
            sendModifierTap(kVK_Control, flag: .maskControl)
        case .rightCtrl:
            sendModifierTap(kVK_RightControl, flag: .maskControl)
        case .leftShift:
            sendModifierTap(kVK_Shift, flag: .maskShift)
        case .rightShift:
            sendModifierTap(kVK_RightShift, flag: .maskShift)
        case .rightOpt:
            sendModifierTap(kVK_RightOption, flag: .maskAlternate)
        case .customShortcut:
            break // HID path resolves the button-specific learned shortcut.
        case .customText:
            break // HID path resolves the button-specific text action.
        case .trackpadClick:
            performClick()
        }
    }

    private func performClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
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
