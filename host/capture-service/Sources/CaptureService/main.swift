import Foundation
import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, CaptureSessionDelegate, VideoEncoderDelegate {
    private var captureSession: CaptureSession?
    private var videoEncoder: VideoEncoder?
    private var ipcClient: IPCClient?
    private var previewController: PreviewWindowController?
    private let config: CaptureConfig

    private var frameCount: Int64 = 0
    private var bytesSent: Int64 = 0
    private var lastStatsTime = Date()

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

        // Initialize video encoder
        do {
            videoEncoder = try VideoEncoder(config: config)
            videoEncoder?.delegate = self
        } catch {
            print("\nFailed to initialize video encoder: \(error)")
            NSApp.terminate(nil)
            return
        }

        // Initialize IPC client
        ipcClient = IPCClient(socketPath: config.ipcSocketPath)
        do {
            try ipcClient?.connect()
        } catch {
            print("\nWarning: IPC connection failed: \(error)")
            print("  Start the webrtc-gateway first, then restart capture-service")
            print("  Continuing without IPC (preview only mode)")
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

        let ipcStatus = ipcClient?.connected == true ? "connected" : "not connected"
        print("\nCapture started (IPC: \(ipcStatus)). Close the preview window or press Ctrl+C to stop.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("\nShutting down...")
        captureSession?.stop()
        videoEncoder?.flush()
        videoEncoder?.invalidate()
        ipcClient?.disconnect()
        print("Capture service stopped.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - CaptureSessionDelegate

    func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer) {
        videoEncoder?.encode(sampleBuffer)
    }

    func captureSession(_ session: CaptureSession, didEncounterError error: Error) {
        print("Capture error: \(error)")
    }

    // MARK: - VideoEncoderDelegate

    func videoEncoder(_ encoder: VideoEncoder, didEncode frame: EncodedVideoFrame) {
        // Send to IPC if connected
        if let client = ipcClient, client.connected {
            do {
                try client.send(frame: frame)
                frameCount += 1
                bytesSent += Int64(frame.data.count)

                // Log stats every 5 seconds
                let now = Date()
                if now.timeIntervalSince(lastStatsTime) >= 5.0 {
                    let mbSent = Double(bytesSent) / 1_000_000.0
                    let elapsed = now.timeIntervalSince(lastStatsTime)
                    let mbps = mbSent / elapsed * 8.0
                    print("Encoded: \(frameCount) frames, \(String(format: "%.1f", mbps)) Mbps")
                    lastStatsTime = now
                    bytesSent = 0
                }
            } catch {
                print("IPC send error: \(error)")
                // Try to reconnect
                if client.reconnect() {
                    print("IPC reconnected")
                }
            }
        }
    }

    func videoEncoder(_ encoder: VideoEncoder, didEncounterError error: Error) {
        print("Encoder error: \(error)")
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
