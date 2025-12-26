---
title: "Local LAN Streaming from Elgato 4K X to Apple Vision Pro"
version: 0.1.0
owner: "Zach"
status: "design-draft"
target_stack:
  host:
    os: "macOS (Apple Silicon preferred)"
    language: "Go + Swift"
    libraries:
      - "AVFoundation (Swift, video/audio capture)"
      - "VideoToolbox (Swift, HW encoding)"
      - "Pion WebRTC (Go, media transport)"
  client:
    os: "visionOS"
    language: "Swift / SwiftUI"
    libraries:
      - "WebRTC iOS SDK (Google libwebrtc)"
      - "RealityKit / SwiftUI for 3D presentation"
primary_transport: "WebRTC over UDP on local LAN"
use_case: "Ultra-low-latency 4K streaming from Elgato 4K X to Vision Pro"
---

# 1. Problem Statement

You want a **custom, low-latency streaming solution** from a **ROG Ally X → Elgato 4K X capture card → macOS host → Apple Vision Pro** that:

- Avoids limitations of third-party apps like Castaway.
- Gives you **full control** over the pipeline (capture, encode, transport, decode, render).
- Targets **4K at 60 FPS** or better with **minimal latency** over a local network.
- Renders on Vision Pro as a **large 2D “cinema” screen** in an immersive space, with future options for curved screens and richer VR UX.

This design describes a system you can implement and iteratively enhance, suitable for automated coding agents like Claude Code.

---

# 2. Requirements

## 2.1 Functional Requirements

1. **Capture**
   - Capture video from Elgato 4K X as a macOS capture device.
   - Capture associated HDMI audio.

2. **Encode**
   - Encode video using **hardware acceleration** (HEVC/H.264 via VideoToolbox).
   - Encode audio to Opus (WebRTC standard) or AAC for internal pipeline before Opus.

3. **Transport**
   - Stream encoded video + audio to Vision Pro over LAN using **WebRTC**.
   - Provide a simple **signaling API** for session setup (offer/answer, ICE).

4. **Vision Pro Client**
   - Connects to host via signaling.
   - Receives WebRTC video/audio.
   - Hardware decodes video and plays audio.
   - Displays content as a floating/curved screen in a spatial scene.

5. **Control & Settings**
   - UI to configure:
     - Resolution (1080p, 1440p, 4K).
     - FPS (30/60).
     - Bitrate preset (low/medium/high).
   - Basic status overlay (latency, FPS, bitrate).

## 2.2 Non-Functional Requirements

- **Latency**: Target glass-to-glass latency ≤ ~60 ms on LAN.
- **Resolution**: Support 1080p60 initially; design to scale to 4K60.
- **Reliability**: Survive capture device reconnects, network blips.
- **Portability**: Host runs on macOS; could later be ported to Linux/Windows capture hosts.
- **Security**: Local network only, but still avoid arbitrary remote code execution. Optional pre-shared key later.

---

# 3. System Overview

## 3.1 High-Level Architecture

Components:

1. **Host Capture Service (Swift)**
   - Captures video/audio from Elgato via AVFoundation.
   - Encodes via VideoToolbox.
   - Feeds compressed samples into a local IPC channel.

2. **Host WebRTC Gateway (Go + Pion)**
   - Receives encoded samples from Capture Service.
   - Wraps them into WebRTC `RTP` packets.
   - Hosts signaling endpoints (HTTP/WebSocket).
   - Manages WebRTC PeerConnections (one Vision Pro client per session).

3. **Vision Pro Client App (SwiftUI / RealityKit + WebRTC)**
   - Implements WebRTC client using iOS WebRTC SDK.
   - Contacts Host WebRTC Gateway for signaling.
   - Receives and decodes media.
   - Renders as a big screen in 3D space.

## 3.2 Data Flow (Happy Path)

1. ROG Ally X → HDMI → Elgato 4K X.
2. Elgato 4K X → USB → macOS host.
3. Host Capture Service:
   - Captures YUV video frames + PCM audio.
   - Encodes frames via VideoToolbox (H.264/HEVC).
   - Sends encoded frames/audio to WebRTC Gateway via local IPC.
4. WebRTC Gateway:
   - Maintains WebRTC PeerConnection(s).
   - Sends encoded frames as RTP video track, audio as RTP audio track.
5. Vision Pro Client:
   - Establishes WebRTC connection.
   - Receives media, decodes via hardware.
   - Displays video on large 2D plane in an ImmersiveSpace.
   - Plays audio through Vision Pro speakers/paired headphones.

---

# 4. Repository Structure

Proposed mono-repo structure (Claude Code friendly):

```text
streaming-project/
  host/
    capture-service/
      cmd/capture-service/main.swift
      Sources/CaptureService/
        CaptureSession.swift
        VideoEncoder.swift
        AudioCapture.swift
        IPCClient.swift
        Config.swift
    webrtc-gateway/
      cmd/webrtc-gateway/main.go
      internal/
        signaling/
          http_server.go
          ws_hub.go
        media/
          pipeline.go
          ipc_consumer.go
        webrtc/
          peer_manager.go
          pion_factory.go
        config/
          config.go
  client-visionos/
    StreamingScreenApp/
      StreamingScreenApp.swift
      Models/
        AppConfig.swift
        ConnectionState.swift
      Networking/
        SignalingClient.swift
        WebRTCClient.swift
      UI/
        RootView.swift
        ControlPanelView.swift
        StatusOverlayView.swift
      Rendering/
        VideoRendererView.swift
        CinemaSpace.swift
  docs/
    design.md
    api-signaling.md
    milestones.md


⸻

5. Host Capture Service (Swift)

5.1 Responsibilities
    •    Discover Elgato 4K X as an input device.
    •    Configure capture session (resolution, frame rate).
    •    Capture video frames (CMSampleBuffer).
    •    Capture audio samples.
    •    Encode video using VideoToolbox (hardware).
    •    (Optionally) encode audio with AAC/Opus or pass raw PCM if the gateway will encode.
    •    Send encoded video/audio via IPC to the Go WebRTC gateway.

5.2 Core Types & Modules

5.2.1 Config.swift (Swift)

struct CaptureConfig {
    var deviceID: String?    // optional; nil = first Elgato-like device
    var width: Int           // e.g., 1920 or 3840
    var height: Int          // e.g., 1080 or 2160
    var fps: Int             // e.g., 60
    var videoCodec: VideoCodec // .h264 or .hevc
    var videoBitrateMbps: Int  // e.g., 25
    var ipcSocketPath: String  // e.g., "/tmp/elgato_stream.sock"
}

enum VideoCodec {
    case h264
    case hevc
}

5.2.2 CaptureSession.swift

Responsibilities:
    •    Set up AVFoundation:
    •    AVCaptureDevice → Elgato video device.
    •    AVCaptureDevice → Elgato audio device.
    •    AVCaptureSession, AVCaptureVideoDataOutput, AVCaptureAudioDataOutput.
    •    Delegate callbacks for sample buffers.

Key interface:

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession,
                        didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
    func captureSession(_ session: CaptureSession,
                        didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
}

final class CaptureSession {
    weak var delegate: CaptureSessionDelegate?

    private let config: CaptureConfig

    init(config: CaptureConfig) {
        self.config = config
    }

    func start() throws { /* configure AVCaptureSession, startRunning() */ }

    func stop() { /* stopRunning() */ }
}

5.2.3 VideoEncoder.swift

Responsibilities:
    •    Wrap VideoToolbox APIs to encode CMSampleBuffer → EncodedFrame (H.264/HEVC).
    •    Provide NALU / Annex B or AVCC format as needed.

Data types:

struct EncodedVideoFrame {
    let pts: CMTime
    let dts: CMTime
    let isKeyFrame: Bool
    let data: Data
}

Interface:

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode frame: EncodedVideoFrame)
}

final class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?

    init(config: CaptureConfig) {
        // setup VTCompressionSession
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        // VTCompressionSessionEncodeFrame(...)
    }

    func flush() { /* end of stream */ }
}

5.2.4 AudioCapture.swift
    •    For v0: optional to encode audio here; you can send raw PCM to the Go gateway and let Pion/Go handle Opus encoding.

struct PCMFrame {
    let pts: CMTime
    let samples: Data  // interleaved
    let sampleRate: Int
    let channels: Int
}

5.2.5 IPCClient.swift

Use a Unix domain socket with a simple framing protocol:
    •    Message header: 1 byte type, 4 bytes length (network order).
    •    Message types:
    •    0x01 = encoded video frame.
    •    0x02 = raw PCM audio frame.

Binary payload:

[MSG_TYPE][LEN(uint32)][JSON_METADATA][BINARY_PAYLOAD]

Where JSON metadata might include:

{
  "pts": 123456789,
  "dts": 123456789,
  "is_key_frame": true,
  "codec": "h264"
}

Swift side:

final class IPCClient {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() throws { /* open unix domain socket */ }

    func sendVideoFrame(_ frame: EncodedVideoFrame) throws { /* encode header+json+data */ }

    func sendAudioFrame(_ frame: PCMFrame) throws { /* similar */ }

    func close() { /* close */ }
}

5.2.6 CaptureService Composition

final class CaptureService: CaptureSessionDelegate, VideoEncoderDelegate {
    private let config: CaptureConfig
    private let captureSession: CaptureSession
    private let videoEncoder: VideoEncoder
    private let ipcClient: IPCClient

    init(config: CaptureConfig) {
        self.config = config
        self.captureSession = CaptureSession(config: config)
        self.videoEncoder = VideoEncoder(config: config)
        self.ipcClient = IPCClient(socketPath: config.ipcSocketPath)
        self.captureSession.delegate = self
        self.videoEncoder.delegate = self
    }

    func start() throws {
        try ipcClient.connect()
        try captureSession.start()
    }

    func stop() {
        captureSession.stop()
        videoEncoder.flush()
        ipcClient.close()
    }

    // CaptureSessionDelegate
    func captureSession(_ session: CaptureSession, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        videoEncoder.encode(sampleBuffer: sampleBuffer)
    }

    func captureSession(_ session: CaptureSession, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        // TODO: convert to PCMFrame and send via IPC
    }

    // VideoEncoderDelegate
    func videoEncoder(_ encoder: VideoEncoder, didEncode frame: EncodedVideoFrame) {
        try? ipcClient.sendVideoFrame(frame)
    }
}

main.swift simply parses CLI flags → CaptureConfig → starts CaptureService.

⸻

6. Host WebRTC Gateway (Go + Pion)

6.1 Responsibilities
    •    Expose signaling API (HTTP or WebSocket).
    •    Manage PeerConnections with Vision Pro clients (usually one).
    •    Consume frames from IPC (Unix socket).
    •    Push frames into Pion video/audio tracks.
    •    Handle ICE, connectivity, and basic monitoring.

6.2 Config

// internal/config/config.go
package config

type Config struct {
    IPCSocketPath   string
    HTTPListenAddr  string // e.g. ":8080"
    AllowedOrigins  []string
    VideoCodec      string // "h264" or "hevc" (if supported)
    MaxBitrateKbps  int
}

6.3 Signaling API

Document in docs/api-signaling.md. Example:

HTTP (simplest to start)
    •    POST /webrtc/offer
    •    Body: { "sdp": "...", "type": "offer" }
    •    Response: { "sdp": "...", "type": "answer" }
    •    POST /webrtc/candidate
    •    Body: { "candidate": "...", "sdpMid": "...", "sdpMLineIndex": 0 }

Later you can upgrade to WebSockets.

6.4 Core Go Modules

6.4.1 IPC Consumer

// internal/media/ipc_consumer.go
package media

type EncodedVideoFrame struct {
    PTS       int64
    DTS       int64
    IsKeyFrame bool
    Codec     string
    Payload   []byte
}

type PCMFrame struct {
    PTS        int64
    SampleRate int
    Channels   int
    Payload    []byte
}

type IPCConsumer struct {
    socketPath string

    VideoFrames chan EncodedVideoFrame
    AudioFrames chan PCMFrame
}

func NewIPCConsumer(socketPath string) *IPCConsumer { /* ... */ }

func (c *IPCConsumer) Start() error {
    // connect to unix socket, parse framed messages, push onto channels
}

func (c *IPCConsumer) Stop() error { /* ... */ }

6.4.2 WebRTC Peer Manager

// internal/webrtc/peer_manager.go
package webrtc

import (
    "github.com/pion/webrtc/v4"
    "sync"
)

type PeerManager struct {
    mu      sync.Mutex
    peer    *webrtc.PeerConnection
    videoTrack *webrtc.TrackLocalStaticSample
    audioTrack *webrtc.TrackLocalStaticSample
}

func NewPeerManager() (*PeerManager, error) {
    // configure webrtc.SettingsEngine, RTCPeerConnection
    // create TrackLocalStaticSample for video and audio
}

func (m *PeerManager) SetRemoteDescription(offer webrtc.SessionDescription) (webrtc.SessionDescription, error) {
    // set remote desc, create answer, set local desc
}

func (m *PeerManager) AddICECandidate(candidate webrtc.ICECandidateInit) error {
    // add candidate
}

func (m *PeerManager) WriteVideoSample(frame EncodedVideoFrame) error {
    // wrap frame.Payload into webrtc.Sample { Data, Duration }
}

func (m *PeerManager) WriteAudioSample(frame PCMFrame) error {
    // similar for audio
}

6.4.3 Media Pipeline

// internal/media/pipeline.go
package media

import (
    "log"
    "time"
    w "streaming-project/host/webrtc-gateway/internal/webrtc"
)

type Pipeline struct {
    IPC   *IPCConsumer
    Peers *w.PeerManager
}

func (p *Pipeline) Start() error {
    go p.consumeVideo()
    go p.consumeAudio()
    return nil
}

func (p *Pipeline) consumeVideo() {
    for frame := range p.IPC.VideoFrames {
        // convert PTS → Duration or timestamp
        err := p.Peers.WriteVideoSample(frame)
        if err != nil {
            log.Printf("error writing video sample: %v", err)
        }
    }
}

func (p *Pipeline) consumeAudio() {
    for frame := range p.IPC.AudioFrames {
        err := p.Peers.WriteAudioSample(frame)
        if err != nil {
            log.Printf("error writing audio sample: %v", err)
        }
    }
}

6.4.4 Signaling HTTP Server

// internal/signaling/http_server.go
package signaling

import (
    "encoding/json"
    "net/http"

    w "streaming-project/host/webrtc-gateway/internal/webrtc"
)

type HTTPServer struct {
    peers *w.PeerManager
}

func NewHTTPServer(peers *w.PeerManager) *HTTPServer { /* ... */ }

func (s *HTTPServer) Routes() http.Handler {
    mux := http.NewServeMux()
    mux.HandleFunc("/webrtc/offer", s.handleOffer)
    mux.HandleFunc("/webrtc/candidate", s.handleCandidate)
    return mux
}

func (s *HTTPServer) handleOffer(w http.ResponseWriter, r *http.Request) {
    var req struct {
        SDP  string `json:"sdp"`
        Type string `json:"type"`
    }
    json.NewDecoder(r.Body).Decode(&req)

    // build webrtc.SessionDescription from req
    // call peers.SetRemoteDescription(...)
    // respond with answer
}

func (s *HTTPServer) handleCandidate(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Candidate     string `json:"candidate"`
        SdpMid        string `json:"sdpMid"`
        SdpMLineIndex uint16 `json:"sdpMLineIndex"`
    }
    json.NewDecoder(r.Body).Decode(&req)

    // build webrtc.ICECandidateInit and call peers.AddICECandidate(...)
    w.WriteHeader(http.StatusNoContent)
}

6.4.5 Main

// cmd/webrtc-gateway/main.go
package main

func main() {
    cfg := config.Load()
    ipc := media.NewIPCConsumer(cfg.IPCSocketPath)
    peers, _ := webrtc.NewPeerManager()
    pipeline := &media.Pipeline{IPC: ipc, Peers: peers}

    go ipc.Start()
    pipeline.Start()

    srv := signaling.NewHTTPServer(peers)
    http.ListenAndServe(cfg.HTTPListenAddr, srv.Routes())
}


⸻

7. VisionOS Client Design

7.1 Responsibilities
    •    Provide a SwiftUI UI to:
    •    Enter host IP/port.
    •    Start/stop streaming.
    •    Adjust a few settings (resolution preset).
    •    Implement WebRTC client:
    •    Create offer.
    •    Send to host signaling API.
    •    Receive answer/candidates.
    •    Handle incoming audio/video tracks.
    •    Render video in a 3D environment as a resizable “screen”.

7.2 Data Models

// Models/AppConfig.swift
struct AppConfig {
    var hostAddress: String  // e.g., "192.168.1.10:8080"
    var resolution: StreamResolution
    var showStats: Bool
}

enum StreamResolution: String, CaseIterable {
    case p1080
    case p1440
    case p2160
}

// Models/ConnectionState.swift
enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error(String)
}

7.3 SignalingClient.swift

final class SignalingClient {
    let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func sendOffer(_ sdp: String, completion: @escaping (Result<String, Error>) -> Void) {
        // POST /webrtc/offer
    }

    func sendCandidate(_ candidate: RTCIceCandidate, completion: @escaping (Result<Void, Error>) -> Void) {
        // POST /webrtc/candidate
    }
}

7.4 WebRTCClient.swift

Using iOS WebRTC SDK (libwebrtc):

import WebRTC

final class WebRTCClient: NSObject {
    private var peerConnectionFactory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection!
    private let signalingClient: SignalingClient

    var onRemoteVideoFrame: ((RTCVideoFrame) -> Void)?
    var onConnectionStateChange: ((RTCIceConnectionState) -> Void)?

    init(signalingClient: SignalingClient) {
        self.signalingClient = signalingClient
        super.init()
        setupPeerConnection()
    }

    private func setupPeerConnection() {
        // configure RTCConfiguration, ICE servers (likely empty for LAN),
        // create peerConnection with delegate = self
    }

    func start() {
        // create offer
        // signalingClient.sendOffer(...)
    }

    func stop() {
        peerConnection.close()
    }

    private func handleRemoteDescription(_ answerSDP: String) {
        // set remote description
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // get video track, set up RTCVideoRenderer
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        onConnectionStateChange?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        signalingClient.sendCandidate(candidate) { _ in }
    }
}

7.5 Rendering / VideoRendererView.swift

Use RTCMTLVideoView or custom renderer, then bridge into SwiftUI:

import SwiftUI
import WebRTC

struct VideoRendererView: UIViewRepresentable {
    let webRTCClient: WebRTCClient

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        webRTCClient.onRemoteVideoFrame = { frame in
            // RTCMTLVideoView can be set as renderer on RTCVideoTrack instead;
            // this callback can be used if you do custom rendering.
        }
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

7.6 CinemaSpace.swift (Immersive Space)

Wrap the video in a 3D space:

import SwiftUI
import RealityKit

struct CinemaSpace: View {
    @ObservedObject var viewModel: CinemaViewModel

    var body: some View {
        RealityView { content in
            // create a plane entity and attach a video material
            // or embed VideoRendererView in a RealityKit plane as a texture
        }
    }
}

For a first version, you can stick to a Windowed SwiftUI app and later upgrade to an ImmersiveSpace.

7.7 RootView.swift

struct RootView: View {
    @StateObject var viewModel = AppViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoRendererView(webRTCClient: viewModel.webRTCClient)
                .edgesIgnoringSafeArea(.all)

            ControlPanelView(viewModel: viewModel)
        }
    }
}


⸻

8. Communication Protocol & Formats

8.1 IPC Protocol (Capture → Gateway)
    •    Unix domain socket.
    •    Frame format:
    •    1 byte type
    •    4 bytes payload length (big-endian)
    •    JSON metadata (UTF-8)
    •    Binary payload (encoded video/audio bytes)

Example metadata (video):

{
  "pts": 123456789,
  "dts": 123456789,
  "is_key_frame": true,
  "codec": "h264"
}

8.2 Signaling Protocol (Gateway ↔ Vision Pro)
    •    HTTP for v0 (easy to test with curl, Postman).
    •    JSON payloads:
    •    Offer: { "sdp": "<base64 or raw sdp>", "type": "offer" }
    •    Answer: { "sdp": "<sdp>", "type": "answer" }
    •    ICE: { "candidate": "...", "sdpMid": "...", "sdpMLineIndex": 0 }

Later, you can replace HTTP with WebSockets for more dynamic operation.

⸻

9. Performance & Quality Considerations
    •    Video Codec: Start with H.264 for interoperability. Test HEVC later.
    •    Bitrate: Start with 15–25 Mbps for 1080p60; adjust for 4K.
    •    Keyframe Interval: 1–2 seconds.
    •    Latency Optimizations:
    •    Hardware encoder low-latency mode.
    •    Avoid unnecessary buffering in capture and gateway.
    •    Use LAN-only ICE configuration (no STUN/TURN).
    •    No simulcast; one video stream only.
    •    Testing Latency: Add debug overlay (client-side) showing:
    •    Frame PTS vs local receive time.
    •    Estimated end-to-end latency.

⸻

10. Development Phases (For You + Claude Code)

Phase 1 – Skeleton & Build System
    •    Create repo with structure above.
    •    Add minimal main.swift for Capture Service and main.go for Gateway.
    •    Add visionOS app scaffold (StreamingScreenApp).

Phase 2 – Capture + Local Preview
    •    Implement CaptureSession to show preview in a Mac test window (not IPC yet).
    •    Ensure 1080p60 capture is stable.

Phase 3 – IPC + Gateway Skeleton
    •    Implement IPCClient (Swift) and IPCConsumer (Go).
    •    Test sending dummy frames.
    •    Add PeerManager with a dummy video track (test sending synthetic frames).

Phase 4 – WebRTC Integration
    •    Integrate Pion in Go and libwebrtc in VisionOS client.
    •    Implement signaling (HTTP).
    •    Make simple 720p stream from synthetic source.

Phase 5 – Real Video
    •    Wire EncodedVideoFrame from Capture Service into Gateway → WebRTC track.
    •    Confirm decode and rendering on Vision Pro.

Phase 6 – Tuning & UX
    •    Add resolution/FPS controls.
    •    Add overlay stats.
    •    Add ImmersiveSpace with curved screen.

⸻

11. Future Enhancements
    •    Bidirectional data channel for:
    •    Remote control (controller/mouse events).
    •    On-the-fly quality adjustments.
    •    HDR support.
    •    Multi-client support (multiple Vision Pros).
    •    Cross-platform host support (Windows/Linux).

⸻

12. Next Steps for Implementation

For the coding agent (e.g., Claude Code), good starting tasks:
    1.    Generate code skeletons for:
    •    host/capture-service/Sources/CaptureService/CaptureSession.swift
    •    host/capture-service/Sources/CaptureService/VideoEncoder.swift
    •    host/capture-service/Sources/CaptureService/IPCClient.swift
    •    host/webrtc-gateway/internal/media/ipc_consumer.go
    •    host/webrtc-gateway/internal/webrtc/peer_manager.go
    •    host/webrtc-gateway/internal/signaling/http_server.go
    •    client-visionos/StreamingScreenApp/Networking/WebRTCClient.swift
    •    client-visionos/StreamingScreenApp/Networking/SignalingClient.swift
    2.    Add basic integration tests:
    •    IPC round-trip test.
    •    Simple HTTP offer/answer test.
    3.    Add build instructions for:
    •    macOS host binaries.
    •    visionOS app via Xcode.

This design should give you enough structure for an automated code generation loop while still leaving room for you to adjust architecture details as you test and learn.


