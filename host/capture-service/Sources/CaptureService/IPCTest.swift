// Simple IPC test - can be run standalone to test connection
import Foundation

/// Runs a simple test to verify IPC connection and protocol
func runIPCTest() {
    print("IPC Protocol Test")
    print("=================")

    let socketPath = "/tmp/elgato_stream.sock"
    print("Connecting to: \(socketPath)")

    let client = IPCClient(socketPath: socketPath)

    do {
        try client.connect()
        print("✓ Connected successfully")
    } catch {
        print("✗ Connection failed: \(error)")
        return
    }

    // Create a test frame with minimal data
    let testData = Data([0x00, 0x00, 0x00, 0x01, 0x67]) // Fake NAL unit start
    let testFrame = EncodedVideoFrame(
        pts: 0,
        dts: 0,
        isKeyFrame: true,
        width: 1920,
        height: 1080,
        codec: .h264,
        data: testData
    )

    print("Sending test frame...")
    print("  PTS: \(testFrame.pts)")
    print("  DTS: \(testFrame.dts)")
    print("  Keyframe: \(testFrame.isKeyFrame)")
    print("  Size: \(testFrame.width)x\(testFrame.height)")
    print("  Codec: \(testFrame.codec.rawValue)")
    print("  Data size: \(testFrame.data.count) bytes")

    do {
        try client.send(frame: testFrame)
        print("✓ Frame sent successfully")
    } catch {
        print("✗ Send failed: \(error)")
    }

    client.disconnect()
    print("✓ Disconnected")
    print("\nTest complete. Check Go gateway logs for received frame.")
}
