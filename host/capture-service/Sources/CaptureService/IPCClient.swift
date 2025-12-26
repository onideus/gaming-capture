import Foundation

enum IPCError: Error, CustomStringConvertible {
    case socketCreationFailed
    case connectionFailed(String)
    case sendFailed(String)
    case notConnected

    var description: String {
        switch self {
        case .socketCreationFailed:
            return "Failed to create socket"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .notConnected:
            return "Not connected to server"
        }
    }
}

// IPC Protocol Constants - matches Go's MessageType
private enum IPCMessageType: UInt8 {
    case video = 0x01
    case audio = 0x02
    case metadata = 0x03
}

// JSON metadata structure for video frames
private struct VideoFrameMetadata: Encodable {
    let pts: Int64
    let dts: Int64
    let keyframe: Bool
    let width: Int
    let height: Int
    let codec: String
}

final class IPCClient {
    private var socketFD: Int32 = -1
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.capture.ipc", qos: .userInteractive)
    private var isConnected = false

    private var retryCount = 0
    private let maxRetries = 5
    private let retryDelay: TimeInterval = 1.0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() throws {
        try queue.sync {
            try connectInternal()
        }
    }

    private func connectInternal() throws {
        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCError.socketCreationFailed
        }

        // Setup address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path to sun_path
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(socketFD)
            socketFD = -1
            throw IPCError.connectionFailed("Socket path too long")
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        // Connect
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, addrLen)
            }
        }

        if result < 0 {
            let errorMsg = String(cString: strerror(errno))
            close(socketFD)
            socketFD = -1
            throw IPCError.connectionFailed(errorMsg)
        }

        isConnected = true
        retryCount = 0
        print("IPC connected to \(socketPath)")
    }

    func send(frame: EncodedVideoFrame) throws {
        guard isConnected else {
            throw IPCError.notConnected
        }

        // Build JSON metadata
        let metadata = VideoFrameMetadata(
            pts: frame.pts,
            dts: frame.dts,
            keyframe: frame.isKeyFrame,
            width: frame.width,
            height: frame.height,
            codec: frame.codec.rawValue
        )

        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(metadata)
        } catch {
            throw IPCError.sendFailed("Failed to encode metadata: \(error)")
        }

        // Protocol: [Type: 1 byte] [Length: 4 bytes BE] [JSON + null] [Payload]
        // Length includes JSON + null terminator + payload
        let totalLength = UInt32(jsonData.count + 1 + frame.data.count)

        var message = Data()

        // Type (1 byte)
        message.append(IPCMessageType.video.rawValue)

        // Length (4 bytes, big-endian)
        var lengthBE = totalLength.bigEndian
        message.append(Data(bytes: &lengthBE, count: 4))

        // JSON metadata
        message.append(jsonData)

        // Null terminator after JSON
        message.append(0x00)

        // Binary payload
        message.append(frame.data)

        // Send complete message
        try queue.sync {
            try sendData(message)
        }
    }

    private func sendData(_ data: Data) throws {
        var totalSent = 0
        let count = data.count

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else { return }

            while totalSent < count {
                let remaining = count - totalSent
                let sent = Darwin.send(
                    socketFD,
                    baseAddress.advanced(by: totalSent),
                    remaining,
                    0
                )

                if sent < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        // Would block - yield and retry
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    let errorMsg = String(cString: strerror(errno))
                    isConnected = false
                    throw IPCError.sendFailed(errorMsg)
                }

                if sent == 0 {
                    isConnected = false
                    throw IPCError.sendFailed("Connection closed by peer")
                }

                totalSent += sent
            }
        }
    }

    func disconnect() {
        queue.sync {
            if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }
            isConnected = false
        }
        print("IPC disconnected")
    }

    func reconnect() -> Bool {
        disconnect()

        guard retryCount < maxRetries else {
            print("IPC max retries (\(maxRetries)) exceeded")
            return false
        }

        retryCount += 1
        print("IPC reconnecting (attempt \(retryCount)/\(maxRetries))...")

        Thread.sleep(forTimeInterval: retryDelay)

        do {
            try connect()
            return true
        } catch {
            print("IPC reconnection failed: \(error)")
            return false
        }
    }

    var connected: Bool {
        queue.sync { isConnected }
    }

    deinit {
        disconnect()
    }
}
