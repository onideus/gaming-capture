import Foundation
import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, CaptureSessionDelegate {
    private var captureSession: CaptureSession?
    private var previewController: PreviewWindowController?
    private let config: CaptureConfig

    init(config: CaptureConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Capture Service starting...")
        print("  Resolution: \(config.width)x\(config.height)@\(config.fps)fps")
        print("  Codec:      \(config.videoCodec.rawValue)")
        print("  Bitrate:    \(config.videoBitrateMbps) Mbps")
        print("  IPC Socket: \(config.ipcSocketPath)")

        // List available devices
        print("\nAvailable capture devices:")
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        for device in discoverySession.devices {
            let marker = device.localizedName.lowercased().contains("elgato") ? " <-- Elgato detected" : ""
            print("  - \(device.localizedName) [\(device.uniqueID)]\(marker)")
        }

        if discoverySession.devices.isEmpty {
            print("  (no external video devices found)")
            print("\nNo capture device available. Exiting.")
            NSApp.terminate(nil)
            return
        }

        // Handle --list-formats
        if config.listFormats {
            for device in discoverySession.devices {
                CaptureSession.listFormats(for: device)
            }
            NSApp.terminate(nil)
            return
        }

        // Initialize capture session
        do {
            captureSession = try CaptureSession(config: config)
            captureSession?.delegate = self
        } catch {
            print("\nFailed to initialize capture session: \(error)")
            NSApp.terminate(nil)
            return
        }

        guard let session = captureSession else { return }

        // Create preview window
        previewController = PreviewWindowController(
            previewLayer: session.previewLayer,
            title: "Elgato Capture"
        )
        previewController?.onClose = {
            NSApp.terminate(nil)
        }
        previewController?.show()
        previewController?.updateTitle(format: session.currentFormat)

        // Start capture
        session.start()

        print("\nCapture started. Close the preview window or press Ctrl+C to stop.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("\nShutting down...")
        captureSession?.stop()
        print("Capture service stopped.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - CaptureSessionDelegate

    func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer) {
        // For now, just receiving frames - encoding will come in Phase 3
    }

    func captureSession(_ session: CaptureSession, didEncounterError error: Error) {
        print("Capture error: \(error)")
    }
}

// Parse config and run app
let config = CaptureConfig.fromCommandLine()

// Setup signal handling
signal(SIGINT) { _ in
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}
signal(SIGTERM) { _ in
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

// Create and run application
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
