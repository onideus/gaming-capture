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
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Find capture device
        let device = try findCaptureDevice()
        self.videoDevice = device

        // Create and add input
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.inputCreationFailed(error.localizedDescription)
        }

        guard session.canAddInput(input) else {
            throw CaptureError.configurationFailed("Cannot add video input to session")
        }
        session.addInput(input)
        self.videoInput = input

        // Configure device format
        try configureDeviceFormat(device)

        // Create and add output
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        // Use BGRA for compatibility
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard session.canAddOutput(output) else {
            throw CaptureError.configurationFailed("Cannot add video output to session")
        }
        session.addOutput(output)
        self.videoOutput = output

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

    private func configureDeviceFormat(_ device: AVCaptureDevice) throws {
        // Find best matching format
        let targetWidth = Int32(config.width)
        let targetHeight = Int32(config.height)
        let targetFPS = Float64(config.fps)

        var bestFormat: AVCaptureDevice.Format?

        for format in device.formats {
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)

            // Check if dimensions match
            if dimensions.width == targetWidth && dimensions.height == targetHeight {
                // Find frame rate range that supports target FPS
                for range in format.videoSupportedFrameRateRanges {
                    if range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS {
                        bestFormat = format
                        break
                    }
                }
            }

            if bestFormat != nil { break }
        }

        // If exact match not found, try to find closest
        if bestFormat == nil {
            print("Exact format \(targetWidth)x\(targetHeight)@\(Int(targetFPS))fps not found, using device default")
            return
        }

        // Apply format
        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat!
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.unlockForConfiguration()
            print("Configured device for \(targetWidth)x\(targetHeight) @ \(Int(targetFPS))fps")
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
