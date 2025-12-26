import AppKit
import AVFoundation

final class PreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        return CALayer()
    }
}

final class PreviewWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let previewView: PreviewView
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let baseTitle: String

    var onClose: (() -> Void)?

    init(previewLayer: AVCaptureVideoPreviewLayer, title: String = "Capture Preview") {
        self.previewLayer = previewLayer
        self.baseTitle = title

        // Create window with 16:9 aspect ratio
        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        previewView = PreviewView(frame: contentRect)

        super.init()

        window.delegate = self
        window.title = title
        window.contentView = previewView
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 640, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        // Add preview layer to view
        previewLayer.frame = previewView.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewView.layer?.addSublayer(previewLayer)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func updateTitle(format: String) {
        window.title = "\(baseTitle) - \(format)"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = previewView.bounds
        CATransaction.commit()
    }
}
