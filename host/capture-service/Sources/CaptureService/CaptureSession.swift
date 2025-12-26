import AVFoundation
import CoreMedia

enum CaptureError: Error, CustomStringConvertible {
    case noDeviceFound
    case deviceNotAvailable(String)
    case configurationFailed(String)
    case inputCreationFailed(String)
    case formatNotSupported(String)

    var description: String {
        switch self {
        case .noDeviceFound:
            return "No external capture device found"
        case .deviceNotAvailable(let msg):
            return "Device not available: \(msg)"
        case .configurationFailed(let msg):
            return "Configuration failed: \(msg)"
        case .inputCreationFailed(let msg):
            return "Failed to create input: \(msg)"
        case .formatNotSupported(let msg):
            return "Format not supported: \(msg)"
        }
    }
}

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer)
    func captureSession(_ session: CaptureSession, didEncounterError error: Error)
}

final class CaptureSession: NSObject {
    private let session: AVCaptureSession
    private let config: CaptureConfig
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let outputQueue = DispatchQueue(label: "com.capture.videoOutput", qos: .userInteractive)

    private var _previewLayer: AVCaptureVideoPreviewLayer?

    weak var delegate: CaptureSessionDelegate?

    var previewLayer: AVCaptureVideoPreviewLayer {
        if let layer = _previewLayer {
            return layer
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        _previewLayer = layer
        return layer
    }

    var isRunning: Bool {
        session.isRunning
    }

    var currentFormat: String {
        guard let device = videoDevice,
              let format = device.activeFormat.formatDescription as CMFormatDescription? else {
            return "Unknown"
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let frameRate = device.activeVideoMinFrameDuration
        let fps = frameRate.timescale > 0 ? Double(frameRate.timescale) / Double(frameRate.value) : 0
        return "\(dimensions.width)x\(dimensions.height) @ \(Int(fps))fps"
    }

    init(config: CaptureConfig) throws {
        self.config = config
        self.session = AVCaptureSession()
        super.init()
        try configureSession()
    }

    private func configureSession() throws {
        // Find capture device
        let device = try findCaptureDevice()
        self.videoDevice = device

        // Configure device format BEFORE adding to session
        // This must happen outside of beginConfiguration/commitConfiguration
        try configureDeviceFormat(device)

        // Now configure the session
        session.beginConfiguration()

        // Create and add input
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CaptureError.inputCreationFailed(error.localizedDescription)
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.configurationFailed("Cannot add video input to session")
        }
        session.addInput(input)
        self.videoInput = input

        // Create and add output
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        // Use BGRA for compatibility
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.configurationFailed("Cannot add video output to session")
        }
        session.addOutput(output)
        self.videoOutput = output

        session.commitConfiguration()

        print("Capture session configured: \(currentFormat)")
    }

    private func findCaptureDevice() throws -> AVCaptureDevice {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        // If specific device ID requested, find it
        if let deviceID = config.deviceID {
            if let device = discoverySession.devices.first(where: { $0.uniqueID == deviceID }) {
                return device
            }
            throw CaptureError.deviceNotAvailable("Device with ID '\(deviceID)' not found")
        }

        // Otherwise, prefer Elgato devices
        if let elgato = discoverySession.devices.first(where: {
            $0.localizedName.lowercased().contains("elgato")
        }) {
            print("Found Elgato device: \(elgato.localizedName)")
            return elgato
        }

        // Fall back to first external device
        if let device = discoverySession.devices.first {
            print("Using external device: \(device.localizedName)")
            return device
        }

        throw CaptureError.noDeviceFound
    }

    static func listFormats(for device: AVCaptureDevice) {
        print("\nAvailable formats for \(device.localizedName):")

        var formatsByResolution: [String: [(format: AVCaptureDevice.Format, fps: [String])]] = [:]

        for format in device.formats {
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)

            let resKey = "\(dimensions.width)x\(dimensions.height)"
            let fpsRanges = format.videoSupportedFrameRateRanges.map { range -> String in
                if range.minFrameRate == range.maxFrameRate {
                    return "\(Int(range.maxFrameRate))"
                } else {
                    return "\(Int(range.minFrameRate))-\(Int(range.maxFrameRate))"
                }
            }

            let entry = (format: format, fps: fpsRanges)
            if formatsByResolution[resKey] == nil {
                formatsByResolution[resKey] = [entry]
            } else {
                formatsByResolution[resKey]?.append(entry)
            }
        }

        // Sort by resolution (descending)
        let sortedKeys = formatsByResolution.keys.sorted { a, b in
            let aWidth = Int(a.split(separator: "x").first ?? "0") ?? 0
            let bWidth = Int(b.split(separator: "x").first ?? "0") ?? 0
            return aWidth > bWidth
        }

        for resKey in sortedKeys {
            guard let entries = formatsByResolution[resKey] else { continue }
            let allFPS = Set(entries.flatMap { $0.fps }).sorted { a, b in
                let aVal = Int(a.split(separator: "-").last ?? "0") ?? 0
                let bVal = Int(b.split(separator: "-").last ?? "0") ?? 0
                return aVal > bVal
            }
            print("  \(resKey): \(allFPS.joined(separator: ", ")) fps")
        }
    }

    private func configureDeviceFormat(_ device: AVCaptureDevice) throws {
        let targetWidth = Int32(config.width)
        let targetHeight = Int32(config.height)
        let targetFPS = Float64(config.fps)

        var bestFormat: AVCaptureDevice.Format?
        var matchedRange: AVFrameRateRange?

        // First pass: find exact resolution match that supports target FPS
        for format in device.formats {
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)

            if dimensions.width == targetWidth && dimensions.height == targetHeight {
                for range in format.videoSupportedFrameRateRanges {
                    // Check if this format supports our target FPS
                    if range.maxFrameRate >= targetFPS && range.minFrameRate <= targetFPS {
                        bestFormat = format
                        matchedRange = range
                        break
                    }
                }
                // If we found exact match, stop searching
                if bestFormat != nil { break }

                // Otherwise take first format at this resolution as fallback
                if bestFormat == nil {
                    bestFormat = format
                    matchedRange = format.videoSupportedFrameRateRanges.first
                }
            }
        }

        // If no exact resolution match, find closest larger resolution
        if bestFormat == nil {
            print("Resolution \(targetWidth)x\(targetHeight) not found, searching for alternatives...")
            CaptureSession.listFormats(for: device)

            var closestFormat: AVCaptureDevice.Format?
            var closestDiff = Int32.max

            for format in device.formats {
                let description = format.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)

                // Only consider formats >= target resolution
                if dimensions.width >= targetWidth && dimensions.height >= targetHeight {
                    let diff = (dimensions.width - targetWidth) + (dimensions.height - targetHeight)

                    if diff < closestDiff {
                        closestFormat = format
                        closestDiff = diff
                        matchedRange = format.videoSupportedFrameRateRanges.first
                    }
                }
            }

            bestFormat = closestFormat
        }

        guard let format = bestFormat else {
            print("No suitable format found, using device default")
            CaptureSession.listFormats(for: device)
            return
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fpsInfo = matchedRange.map { "\(Int($0.maxFrameRate))fps max" } ?? "unknown fps"
        print("Applying format: \(dims.width)x\(dims.height) (\(fpsInfo))...")

        // Apply format - NOTE: For capture cards, we only set the format.
        // Frame rate is determined by the input signal, not software settings.
        // Setting activeVideoMinFrameDuration can block indefinitely on capture cards.
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()

            print("Configured device for \(dims.width)x\(dims.height)")
            print("  (Frame rate is determined by input signal)")
        } catch {
            throw CaptureError.configurationFailed("Failed to configure device: \(error.localizedDescription)")
        }
    }

    func start() {
        guard !session.isRunning else { return }
        print("Starting capture session...")
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        print("Stopping capture session...")
        session.stopRunning()
    }
}

extension CaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate?.captureSession(self, didOutput: sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped - could log this for debugging
    }
}
