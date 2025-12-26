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

// IPC Protocol Constants
private enum IPCFrameType: UInt8 {
    case h264 = 0x01
    case hevc = 0x02
    case audioPCM = 0x10
}

private enum IPCFlags: UInt8 {
    case none = 0x00
    case keyframe = 0x01
}

// Header: Type(1) + Flags(1) + PTS(8) + Length(4) = 14 bytes
private let headerSize = 14

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

        // Build header
        var header = Data(capacity: headerSize)

        // Type (1 byte)
        let frameType: UInt8 = frame.codec == .hevc ? IPCFrameType.hevc.rawValue : IPCFrameType.h264.rawValue
        header.append(frameType)

        // Flags (1 byte)
        let flags: UInt8 = frame.isKeyFrame ? IPCFlags.keyframe.rawValue : IPCFlags.none.rawValue
        header.append(flags)

        // PTS (8 bytes, little-endian)
        var pts = frame.pts.littleEndian
        header.append(Data(bytes: &pts, count: 8))

        // Length (4 bytes, little-endian)
        var length = UInt32(frame.data.count).littleEndian
        header.append(Data(bytes: &length, count: 4))

        // Send header + payload
        try queue.sync {
            try sendData(header)
            try sendData(frame.data)
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
