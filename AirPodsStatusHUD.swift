//
//  AirPodsStatusHUD.swift
//  Wand
//
//  A non-activating status overlay for AirPods operations. It never steals keyboard focus
//  from Mac TV or the current app and automatically dismisses completed states.
//

import AppKit

final class AirPodsStatusHUD {
    private let panel: NSPanel
    private let symbolView: NSImageView
    private let spinner: NSProgressIndicator
    private let messageLabel: NSTextField
    private var presentationGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let material = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.borderWidth = 0.5
        material.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        material.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = material

        symbolView = NSImageView()
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        symbolView.contentTintColor = .labelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(symbolView)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(spinner)

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 14, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            symbolView.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 24),
            symbolView.heightAnchor.constraint(equalToConstant: 24),
            spinner.centerXAnchor.constraint(equalTo: symbolView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: symbolView.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 15),
            messageLabel.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            messageLabel.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
    }

    func show(message: String, state: AirPodsFeedbackState) {
        precondition(Thread.isMainThread)
        presentationGeneration += 1
        let generation = presentationGeneration
        messageLabel.stringValue = message
        let symbolName: String
        switch state {
        case .progress: symbolName = "airpodspro"
        case .success:  symbolName = "checkmark.circle.fill"
        case .failure:  symbolName = "exclamationmark.triangle.fill"
        }
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        if state == .progress {
            symbolView.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            symbolView.isHidden = false
        }

        positionOnActiveScreen()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0.88
        }

        // Progress normally gets replaced by a completion message. The long fallback keeps
        // a lost Bluetooth callback from leaving the overlay on screen forever.
        let duration: TimeInterval = state == .progress ? 35 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.dismiss()
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 24
        ))
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}
