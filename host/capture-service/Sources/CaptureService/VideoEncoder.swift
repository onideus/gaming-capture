import Foundation
import VideoToolbox
import CoreMedia

enum EncoderError: Error, CustomStringConvertible {
    case sessionCreationFailed(OSStatus)
    case configurationFailed(String)
    case encodingFailed(OSStatus)

    var description: String {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create compression session: \(status)"
        case .configurationFailed(let msg):
            return "Encoder configuration failed: \(msg)"
        case .encodingFailed(let status):
            return "Encoding failed: \(status)"
        }
    }
}

struct EncodedVideoFrame {
    let pts: Int64           // microseconds
    let dts: Int64           // microseconds
    let isKeyFrame: Bool
    let width: Int
    let height: Int
    let codec: VideoCodec
    let data: Data           // Annex B NAL units
}

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode frame: EncodedVideoFrame)
    func videoEncoder(_ encoder: VideoEncoder, didEncounterError error: Error)
}

final class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private let config: CaptureConfig
    private let encoderQueue = DispatchQueue(label: "com.capture.encoder", qos: .userInteractive)

    weak var delegate: VideoEncoderDelegate?

    private var frameCount: Int64 = 0
    private var spsData: Data?
    private var ppsData: Data?

    init(config: CaptureConfig) throws {
        self.config = config
        try createCompressionSession()
    }

    private func createCompressionSession() throws {
        let codecType: CMVideoCodecType = config.videoCodec == .hevc
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264

        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]

        let imageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: codecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: imageBufferAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        self.compressionSession = session
        try configureSession(session)
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding
        var status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard status == noErr else {
            throw EncoderError.configurationFailed("Failed to set real-time mode")
        }

        // Bitrate
        let bitrate = config.videoBitrateMbps * 1_000_000
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrate as CFNumber
        )

        // Data rate limits (peak bitrate = 1.5x average)
        let bytesPerSecond = Double(bitrate) / 8.0
        let peakBytesPerSecond = bytesPerSecond * 1.5
        let limits: [Double] = [peakBytesPerSecond, 1.0] // bytes, seconds
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: limits as CFArray
        )

        // Keyframe interval (every 2 seconds worth of frames at 60fps = 120 frames)
        let keyframeInterval = config.fps * 2
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: keyframeInterval as CFNumber
        )

        // Profile level for H.264
        if config.videoCodec == .h264 {
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Main_AutoLevel
            )

            // Allow frame reordering = false for lower latency
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse
            )
        }

        // Prepare to encode
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else {
            throw EncoderError.configurationFailed("Failed to prepare encoder")
        }

        print("Video encoder initialized: \(config.videoCodec.rawValue) @ \(config.videoBitrateMbps) Mbps")
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        encoderQueue.async { [weak self] in
            self?.encodeFrame(session: session, imageBuffer: imageBuffer, pts: pts, duration: duration)
        }
    }

    private func encodeFrame(
        session: VTCompressionSession,
        imageBuffer: CVImageBuffer,
        pts: CMTime,
        duration: CMTime
    ) {
        var flags: VTEncodeInfoFlags = []

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleEncodedFrame(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            delegate?.videoEncoder(self, didEncounterError: EncoderError.encodingFailed(status))
        }

        frameCount += 1
    }

    private func handleEncodedFrame(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard status == noErr else {
            delegate?.videoEncoder(self, didEncounterError: EncoderError.encodingFailed(status))
            return
        }

        guard let sampleBuffer = sampleBuffer else { return }

        // Check if keyframe
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyFrame = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        // Get timing info
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let ptsUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        let dtsUs = Int64(CMTimeGetSeconds(dts.isValid ? dts : pts) * 1_000_000)

        // Convert to Annex B format
        guard let data = convertToAnnexB(sampleBuffer: sampleBuffer, isKeyFrame: isKeyFrame) else {
            return
        }

        let frame = EncodedVideoFrame(
            pts: ptsUs,
            dts: dtsUs,
            isKeyFrame: isKeyFrame,
            width: config.width,
            height: config.height,
            codec: config.videoCodec,
            data: data
        )

        delegate?.videoEncoder(self, didEncode: frame)
    }

    private func convertToAnnexB(sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else { return nil }

        var result = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])

        // For keyframes, prepend SPS/PPS
        if isKeyFrame {
            if config.videoCodec == .h264 {
                if let parameterSets = extractH264ParameterSets(formatDesc) {
                    for parameterSet in parameterSets {
                        result.append(startCode)
                        result.append(parameterSet)
                    }
                }
            } else {
                if let parameterSets = extractHEVCParameterSets(formatDesc) {
                    for parameterSet in parameterSets {
                        result.append(startCode)
                        result.append(parameterSet)
                    }
                }
            }
        }

        // Convert AVCC/HVCC NAL units to Annex B
        var offset = 0
        let nalLengthSize = config.videoCodec == .h264 ? 4 : 4

        while offset < totalLength {
            // Read NAL unit length
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer.advanced(by: offset), nalLengthSize)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += nalLengthSize

            guard offset + Int(nalLength) <= totalLength else { break }

            // Write start code + NAL unit
            result.append(startCode)
            result.append(Data(bytes: dataPointer.advanced(by: offset), count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return result
    }

    private func extractH264ParameterSets(_ formatDesc: CMFormatDescription) -> [Data]? {
        var parameterSets: [Data] = []

        var spsSize = 0
        var spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?

        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr, let sps = spsPointer {
            parameterSets.append(Data(bytes: sps, count: spsSize))
        }

        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?

        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        if status == noErr, let pps = ppsPointer {
            parameterSets.append(Data(bytes: pps, count: ppsSize))
        }

        return parameterSets.isEmpty ? nil : parameterSets
    }

    private func extractHEVCParameterSets(_ formatDesc: CMFormatDescription) -> [Data]? {
        var parameterSets: [Data] = []

        // VPS (index 0), SPS (index 1), PPS (index 2)
        for index in 0..<3 {
            var size = 0
            var pointer: UnsafePointer<UInt8>?

            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            if status == noErr, let ptr = pointer {
                parameterSets.append(Data(bytes: ptr, count: size))
            }
        }

        return parameterSets.isEmpty ? nil : parameterSets
    }

    func flush() {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    deinit {
        invalidate()
    }
}
