import AppKit

/// Top-origin document view. NSScrollView's clip view is not flipped by default, so a document
/// shorter than the visible area gets pinned to the BOTTOM (the blank-space-on-top bug). A
/// flipped document lays its content out from the top down and scrolls naturally.
private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A standalone, always-available "How to Pair" window opened from the menu-bar dropdown.
/// Content is fully localized (see `pairing.*` keys); this file holds only layout + behavior,
/// so refining the wording never touches code.
final class PairingGuideController: NSWindowController {

    /// Localization keys for the ordered pairing steps. Add/remove keys here and in the
    /// Localizable.strings files together — the view renders whatever this array lists.
    private static let stepKeys = [
        "pairing.step1",
        "pairing.step2",
        "pairing.step3",
        "pairing.step4",
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("pairing.windowTitle")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        // ── Bottom button bar (fixed) ────────────────────────────────────────
        let bluetoothButton = NSButton(title: tr("pairing.openBluetooth"),
                                       target: self, action: #selector(openBluetoothSettings))
        bluetoothButton.bezelStyle = .rounded
        bluetoothButton.keyEquivalent = "\r"   // default button

        let closeButton = NSButton(title: tr("pairing.close"),
                                   target: self, action: #selector(closeGuide))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"   // Esc

        let buttonBar = NSStackView(views: [closeButton, bluetoothButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 12
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonBar)

        // ── Scrollable body ──────────────────────────────────────────────────
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.translatesAutoresizingMaskIntoConstraints = false
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let heading = NSTextField(labelWithString: tr("pairing.heading"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        body.addArrangedSubview(heading)

        let intro = NSTextField(wrappingLabelWithString: tr("pairing.intro"))
        intro.textColor = .secondaryLabelColor
        body.addArrangedSubview(intro)

        for (index, key) in Self.stepKeys.enumerated() {
            body.addArrangedSubview(makeStepRow(number: index + 1, text: tr(key)))
        }

        let tips = NSTextField(wrappingLabelWithString: tr("pairing.tips"))
        tips.font = .systemFont(ofSize: 12)
        tips.textColor = .secondaryLabelColor
        body.addArrangedSubview(tips)

        // Flipped document container so content lays out from the top down (see type doc above).
        let doc = TopAlignedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc

        content.addSubview(scroll)

        let clip = scroll.contentView   // NSClipView
        NSLayoutConstraint.activate([
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),

            // Document tracks the clip's top + width so only vertical scrolling occurs and
            // content starts at the top; its height is driven by `body` below.
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            // Body fills the document — pinning all four edges makes body's height the scroll height.
            body.topAnchor.constraint(equalTo: doc.topAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    /// A numbered step: a fixed-width bold index followed by a wrapping description.
    private func makeStepRow(number: Int, text: String) -> NSView {
        let badge = NSTextField(labelWithString: "\(number).")
        badge.font = .systemFont(ofSize: 13, weight: .bold)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)

        let row = NSStackView(views: [badge, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    @objc private func openBluetoothSettings() {
        // The Bluetooth pane's anchor is the System Settings extension bundle id, which changed
        // with the Ventura rewrite. `com.apple.BluetoothSettings` is the ExtensionKit id used on
        // Ventura through macOS 26 (verified on this machine); the last entry is the pre-Ventura
        // prefPane fallback. NSWorkspace.open returns true once System Settings launches (it can't
        // report whether the anchor resolved), so the CORRECT id must come first.
        let candidates = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preference.bluetooth",
        ]
        for str in candidates {
            if let url = URL(string: str), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func closeGuide() {
        window?.close()
    }
}
