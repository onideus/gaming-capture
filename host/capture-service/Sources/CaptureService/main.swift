import Foundation
import AVFoundation

let config = CaptureConfig.fromCommandLine()

print("Capture Service starting...")
print("  Resolution: \(config.width)x\(config.height)@\(config.fps)fps")
print("  Codec:      \(config.videoCodec.rawValue)")
print("  Bitrate:    \(config.videoBitrateMbps) Mbps")
print("  IPC Socket: \(config.ipcSocketPath)")

// List available capture devices
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
}

// Setup signal handling for graceful shutdown
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

var shouldExit = false

sigintSource.setEventHandler {
    print("\nReceived SIGINT, shutting down...")
    shouldExit = true
}

sigtermSource.setEventHandler {
    print("\nReceived SIGTERM, shutting down...")
    shouldExit = true
}

sigintSource.resume()
sigtermSource.resume()

print("\nCapture service ready. Press Ctrl+C to stop.")

// Run loop - will be replaced with actual capture logic
while !shouldExit {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
}

print("Capture service stopped.")
