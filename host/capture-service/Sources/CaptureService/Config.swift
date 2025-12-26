import Foundation

enum VideoCodec: String {
    case h264
    case hevc
}

struct CaptureConfig {
    var deviceID: String?       // nil = first Elgato-like device
    var width: Int              // e.g., 1920 or 3840
    var height: Int             // e.g., 1080 or 2160
    var fps: Int                // e.g., 60
    var videoCodec: VideoCodec  // .h264 or .hevc
    var videoBitrateMbps: Int   // e.g., 25
    var ipcSocketPath: String   // e.g., "/tmp/elgato_stream.sock"
    var listFormats: Bool       // just list formats and exit
    var testIPC: Bool           // run IPC test and exit

    static func fromCommandLine() -> CaptureConfig {
        var config = CaptureConfig(
            deviceID: nil,
            width: 1920,
            height: 1080,
            fps: 60,
            videoCodec: .h264,
            videoBitrateMbps: 25,
            ipcSocketPath: "/tmp/elgato_stream.sock",
            listFormats: false,
            testIPC: false
        )

        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--width":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    config.width = val
                    i += 1
                }
            case "--height":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    config.height = val
                    i += 1
                }
            case "--fps":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    config.fps = val
                    i += 1
                }
            case "--codec":
                if i + 1 < args.count {
                    config.videoCodec = args[i + 1] == "hevc" ? .hevc : .h264
                    i += 1
                }
            case "--bitrate":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    config.videoBitrateMbps = val
                    i += 1
                }
            case "--socket":
                if i + 1 < args.count {
                    config.ipcSocketPath = args[i + 1]
                    i += 1
                }
            case "--device":
                if i + 1 < args.count {
                    config.deviceID = args[i + 1]
                    i += 1
                }
            case "--list-formats":
                config.listFormats = true
            case "--test-ipc":
                config.testIPC = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                break
            }
            i += 1
        }

        // Environment variable overrides
        if let val = ProcessInfo.processInfo.environment["CAPTURE_WIDTH"], let width = Int(val) {
            config.width = width
        }
        if let val = ProcessInfo.processInfo.environment["CAPTURE_HEIGHT"], let height = Int(val) {
            config.height = height
        }
        if let val = ProcessInfo.processInfo.environment["IPC_SOCKET_PATH"] {
            config.ipcSocketPath = val
        }

        return config
    }

    private static func printUsage() {
        print("""
        Usage: capture-service [options]

        Options:
          --width <int>      Video width (default: 1920)
          --height <int>     Video height (default: 1080)
          --fps <int>        Frame rate (default: 60)
          --codec <str>      Video codec: h264 or hevc (default: h264)
          --bitrate <int>    Video bitrate in Mbps (default: 25)
          --socket <path>    IPC socket path (default: /tmp/elgato_stream.sock)
          --device <id>      Capture device ID (default: auto-detect Elgato)
          --list-formats     List available capture formats and exit
          --test-ipc         Test IPC connection and exit
          --help, -h         Show this help
        """)
    }
}
