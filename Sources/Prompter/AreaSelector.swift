import AppKit

/// Seleção de área: escurece todas as telas e deixa desenhar um retângulo. Esc cancela.
@MainActor
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var completion: ((ScreenSource?) -> Void)?

    func begin(_ completion: @escaping (ScreenSource?) -> Void) {
        cancel()
        self.completion = completion
        for screen in NSScreen.screens {
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in self?.finish(rect, on: screen) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate()
        windows.first { $0.screen == NSScreen.main }?.makeKey()
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: CGRect?, on screen: NSScreen) {
        let callback = completion
        cancel()
        guard let rect, rect.width >= 80, rect.height >= 60 else { callback?(nil); return }
        // ScreenCaptureKit usa pontos com origem no canto superior esquerdo da tela.
        let top = screen.frame.height - rect.maxY
        callback?(.area(display: screen.displayID, x: rect.minX.rounded(), y: top.rounded(),
                        width: rect.width.rounded(), height: rect.height.rounded()))
    }

    private func cancel() {
        if !windows.isEmpty { NSCursor.pop() }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion = nil
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let rect = selection else {
            hint(L("Arraste para escolher a área. Esc cancela.", "Drag to choose the area. Esc cancels."), at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
        hint("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.midX, y: rect.minY - 22))
    }

    private func hint(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: point.x - size.width / 2 - 10, y: max(8, point.y - size.height / 2 - 5),
                         width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
