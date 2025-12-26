# VisionOS Client Dependencies

## WebRTC SDK

This project requires the WebRTC SDK for visionOS. The code is designed with conditional compilation (`#if canImport(WebRTC)`) so it compiles even without the SDK installed.

### Option 1: stasel/WebRTC (Recommended)

The most popular WebRTC Swift Package for iOS:

1. Open `StreamingScreenApp.xcodeproj` in Xcode
2. Go to File → Add Package Dependencies...
3. Enter URL: `https://github.com/stasel/WebRTC.git`
4. Select version: Up to Next Major (latest)
5. Add `WebRTC` library to the `StreamingScreenApp` target

**Note:** This package may require building for visionOS. If it doesn't work directly, see Option 3.

### Option 2: AimTune's WebRTC (visionOS Builds)

If you need pre-built visionOS support:

1. Check `https://github.com/nickklock/nickkWebRTC` for visionOS-compatible builds
2. Or search for "WebRTC visionOS" on GitHub for community forks

### Option 3: Build WebRTC from Source

For full visionOS support, you may need to build WebRTC from source:

1. Clone Google's WebRTC: `https://webrtc.googlesource.com/src`
2. Follow the iOS build instructions
3. Modify the build scripts to target visionOS (xros) architecture
4. Build the xcframework and add it manually

### Option 4: Manual XCFramework Integration

If SPM doesn't work:

1. Download or build `WebRTC.xcframework`
2. Drag it into the Xcode project
3. In target settings, ensure "Embed & Sign" is selected
4. Add the framework search path if needed

## Running Without WebRTC SDK

The codebase is designed to compile and run without the WebRTC SDK:

- All WebRTC code is wrapped in `#if canImport(WebRTC)`
- Mock implementations are provided for testing
- The app will show "Mock Mode" warnings when running without WebRTC

This allows you to:
- Build and test the UI without the SDK
- Develop signaling logic independently
- Add the real SDK when available for visionOS

## Verification

After adding the dependency, verify it works:

```swift
#if canImport(WebRTC)
import WebRTC

// Test that types are available
let _ = RTCPeerConnectionFactory.self
print("WebRTC SDK is available")
#else
print("Running in mock mode - WebRTC SDK not available")
#endif
```

## Version Compatibility

- Minimum visionOS version: 1.0
- WebRTC library version: Latest available
- Swift version: 5.9+

## Troubleshooting

### "No such module 'WebRTC'"

This error means the SDK isn't properly linked:
1. Check Package Dependencies in Xcode
2. Ensure the library is added to your target
3. Clean build folder (Cmd+Shift+K) and rebuild

### Architecture Errors

visionOS uses the `xros` architecture. If you get architecture errors:
1. The package may not support visionOS yet
2. Try building WebRTC from source for visionOS
3. Check for community forks with visionOS support

### Simulator vs Device

WebRTC may behave differently on simulator vs device:
- Simulator: `x86_64` or `arm64-simulator`
- Device: `arm64` for visionOS

Ensure your WebRTC build includes all required architectures.
