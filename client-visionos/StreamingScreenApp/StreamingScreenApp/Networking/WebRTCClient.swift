//
//  WebRTCClient.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation
import AVFoundation
import os.log

#if canImport(WebRTC)
import WebRTC
#endif

/// Client for managing WebRTC peer connections
///
/// This class handles the WebRTC connection lifecycle:
/// - Creates peer connection with receive-only configuration
/// - Generates SDP offers and processes answers
/// - Manages ICE candidate exchange
/// - Notifies delegate of state changes and incoming video tracks
///
/// Uses conditional compilation to support building without the WebRTC SDK.
@MainActor
class WebRTCClient: NSObject {
    // MARK: - Types
    
    /// Delegate protocol for WebRTC events
    protocol Delegate: AnyObject {
        /// Called when the connection state changes
        func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: ConnectionState)
        
        /// Called when a remote video track is received
        func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: Any)
        
        /// Called when a local ICE candidate is generated
        func webRTCClient(_ client: WebRTCClient, didGenerateLocalCandidate candidate: ICECandidateMessage)
        
        /// Called when an error occurs
        func webRTCClient(_ client: WebRTCClient, didReceiveError error: StreamingError)
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.gamingcapture.app", category: "WebRTCClient")
    private let config: AppConfig
    private let signalingClient: SignalingClient
    
    /// Delegate for receiving WebRTC events
    weak var delegate: Delegate?
    
    /// Current connection state
    private(set) var connectionState: ConnectionState = .disconnected
    
    // WebRTC components (when SDK is available)
    #if canImport(WebRTC)
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    #endif
    
    // ICE candidate queue (for trickle ICE before remote description is set)
    private var pendingCandidates: [ICECandidateMessage] = []
    
    /// Whether the remote description has been set
    private var hasRemoteDescription: Bool = false
    
    // MARK: - Initialization
    
    /// Initialize the WebRTC client
    /// - Parameters:
    ///   - config: Application configuration
    ///   - signalingClient: Signaling client for offer/answer exchange
    init(config: AppConfig, signalingClient: SignalingClient) {
        self.config = config
        self.signalingClient = signalingClient
        super.init()
        
        #if canImport(WebRTC)
        setupWebRTC()
        #else
        logger.warning("WebRTC SDK not available - running in mock mode")
        #endif
    }
    
    deinit {
        #if canImport(WebRTC)
        peerConnection?.close()
        RTCCleanupSSL()
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Start the WebRTC connection
    ///
    /// This method:
    /// 1. Checks server health
    /// 2. Creates peer connection
    /// 3. Generates SDP offer
    /// 4. Sends offer to server and receives answer
    /// 5. Sets remote description
    /// 6. Applies any pending ICE candidates
    ///
    /// - Throws: `StreamingError` if connection fails
    func connect() async throws {
        guard connectionState == .disconnected || connectionState == .closed else {
            logger.warning("Already connecting or connected, current state: \(self.connectionState.statusText)")
            return
        }
        
        updateState(.connecting)
        
        do {
            // 1. Check server health first
            logger.info("Checking server health...")
            let health = try await signalingClient.checkHealth()
            logger.info("Server healthy, \(health.peers) peers connected, uptime: \(health.uptime)")
            
            // 2. Create peer connection if not exists
            #if canImport(WebRTC)
            if peerConnection == nil {
                createPeerConnection()
            }
            #endif
            
            // 3. Create offer
            logger.info("Creating SDP offer...")
            updateState(.signaling)
            
            #if canImport(WebRTC)
            let offer = try await createOffer()
            
            // 4. Send offer and get answer
            logger.info("Sending offer to server...")
            let answer = try await signalingClient.sendOffer(offer.sdp)
            
            // 5. Set remote description
            logger.info("Setting remote description...")
            try await setRemoteDescription(answer)
            hasRemoteDescription = true
            
            // 6. Apply any pending ICE candidates
            await applyPendingCandidates()
            
            updateState(.iceNegotiating)
            logger.info("ICE negotiation started")
            #else
            // Mock implementation when WebRTC is not available
            logger.warning("WebRTC SDK not available - using mock implementation")
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            updateState(.connected)
            logger.info("Mock connection established")
            #endif
            
        } catch {
            let streamingError: StreamingError
            if let se = error as? StreamingError {
                streamingError = se
            } else {
                streamingError = .connectionFailed(error.localizedDescription)
            }
            
            logger.error("Connection failed: \(streamingError.localizedDescription)")
            updateState(.failed(streamingError.localizedDescription ?? "Unknown error"))
            delegate?.webRTCClient(self, didReceiveError: streamingError)
            throw streamingError
        }
    }
    
    /// Disconnect the WebRTC connection
    ///
    /// Closes the peer connection, clears pending candidates, and resets signaling client.
    func disconnect() {
        logger.info("Disconnecting WebRTC client...")
        
        #if canImport(WebRTC)
        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil
        localVideoTrack = nil
        localAudioTrack = nil
        #endif
        
        pendingCandidates.removeAll()
        hasRemoteDescription = false
        
        Task {
            await signalingClient.reset()
        }
        
        updateState(.closed)
        logger.info("WebRTC client disconnected")
    }
    
    /// Add a remote ICE candidate
    ///
    /// If the remote description hasn't been set yet, the candidate is queued
    /// and will be applied once the remote description is set.
    ///
    /// - Parameter candidate: The ICE candidate message from the server
    func addRemoteCandidate(_ candidate: ICECandidateMessage) {
        logger.debug("Adding remote ICE candidate: \(candidate.candidate)")
        
        #if canImport(WebRTC)
        if hasRemoteDescription, let pc = peerConnection {
            let rtcCandidate = RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
                sdpMid: candidate.sdpMid
            )
            pc.add(rtcCandidate)
            logger.debug("Applied remote ICE candidate")
        } else {
            pendingCandidates.append(candidate)
            logger.debug("Queued remote ICE candidate (waiting for remote description)")
        }
        #else
        pendingCandidates.append(candidate)
        logger.debug("Queued remote ICE candidate (mock mode)")
        #endif
    }
    
    /// Get connection statistics
    ///
    /// Returns basic stats about the current connection.
    /// - Returns: Dictionary with connection statistics
    func getStats() async -> [String: Any] {
        var stats: [String: Any] = [
            "state": connectionState.statusText,
            "pendingCandidates": pendingCandidates.count,
            "hasRemoteDescription": hasRemoteDescription
        ]
        
        #if canImport(WebRTC)
        stats["hasPeerConnection"] = peerConnection != nil
        stats["hasRemoteVideoTrack"] = remoteVideoTrack != nil
        #else
        stats["mockMode"] = true
        #endif
        
        return stats
    }
    
    // MARK: - Private Methods
    
    /// Update the connection state and notify delegate
    private func updateState(_ state: ConnectionState) {
        let previousState = connectionState
        connectionState = state
        
        if previousState != state {
            logger.info("Connection state changed: \(previousState.statusText) -> \(state.statusText)")
            delegate?.webRTCClient(self, didChangeConnectionState: state)
        }
    }
    
    #if canImport(WebRTC)
    /// Initialize WebRTC infrastructure
    private func setupWebRTC() {
        logger.debug("Setting up WebRTC...")
        
        // Initialize WebRTC SSL
        RTCInitializeSSL()
        
        // Create peer connection factory with default encoders/decoders
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        
        peerConnectionFactory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        
        logger.info("WebRTC initialized successfully")
    }
    
    /// Create the RTCPeerConnection with appropriate configuration
    private func createPeerConnection() {
        guard let factory = peerConnectionFactory else {
            logger.error("Cannot create peer connection: factory not initialized")
            return
        }
        
        logger.debug("Creating peer connection...")
        
        // ICE configuration - LAN only, no STUN/TURN needed for local network
        let rtcConfig = RTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.iceTransportPolicy = .all
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.rtcpMuxPolicy = .require
        rtcConfig.continualGatheringPolicy = .gatherContinually
        
        // For LAN-only operation, we don't need ICE servers
        // The host and client should be on the same network
        rtcConfig.iceServers = []
        
        // Create constraints
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        // Create peer connection
        peerConnection = factory.peerConnection(
            with: rtcConfig,
            constraints: constraints,
            delegate: self
        )
        
        // Add transceivers for receiving video/audio (receive-only mode)
        if let pc = peerConnection {
            // Video transceiver - receive only since we're just viewing the screen
            let videoTransceiver = pc.addTransceiver(of: .video)
            videoTransceiver?.setDirection(.recvOnly, error: nil)
            
            // Audio transceiver - receive only for system audio
            let audioTransceiver = pc.addTransceiver(of: .audio)
            audioTransceiver?.setDirection(.recvOnly, error: nil)
            
            logger.info("Peer connection created with receive-only transceivers")
        } else {
            logger.error("Failed to create peer connection")
        }
    }
    
    /// Create an SDP offer and set it as local description
    private func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw StreamingError.webRTCError("No peer connection available")
        }
        
        // Constraints for the offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: nil
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { [weak self] sdp, error in
                guard let self = self else {
                    continuation.resume(throwing: StreamingError.webRTCError("Client deallocated"))
                    return
                }
                
                if let error = error {
                    self.logger.error("Failed to create offer: \(error.localizedDescription)")
                    continuation.resume(throwing: StreamingError.webRTCError(error.localizedDescription))
                    return
                }
                
                guard let sdp = sdp else {
                    self.logger.error("No SDP generated")
                    continuation.resume(throwing: StreamingError.webRTCError("No SDP generated"))
                    return
                }
                
                self.logger.debug("Created SDP offer, setting as local description...")
                
                // Set local description
                pc.setLocalDescription(sdp) { setError in
                    if let setError = setError {
                        self.logger.error("Failed to set local description: \(setError.localizedDescription)")
                        continuation.resume(throwing: StreamingError.webRTCError(setError.localizedDescription))
                    } else {
                        self.logger.info("Local description set successfully")
                        continuation.resume(returning: sdp)
                    }
                }
            }
        }
    }
    
    /// Set the remote SDP answer
    private func setRemoteDescription(_ answer: SDPAnswer) async throws {
        guard let pc = peerConnection else {
            throw StreamingError.webRTCError("No peer connection available")
        }
        
        let sdp = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to set remote description: \(error.localizedDescription)")
                    continuation.resume(throwing: StreamingError.webRTCError(error.localizedDescription))
                } else {
                    self?.logger.info("Remote description set successfully")
                    continuation.resume()
                }
            }
        }
    }
    
    /// Apply any pending ICE candidates that were queued before remote description was set
    private func applyPendingCandidates() async {
        guard let pc = peerConnection else { return }
        
        if pendingCandidates.isEmpty {
            logger.debug("No pending ICE candidates to apply")
            return
        }
        
        logger.info("Applying \(self.pendingCandidates.count) pending ICE candidates")
        
        for candidate in pendingCandidates {
            let rtcCandidate = RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
                sdpMid: candidate.sdpMid
            )
            pc.add(rtcCandidate)
        }
        
        pendingCandidates.removeAll()
        logger.debug("All pending ICE candidates applied")
    }
    #endif
}

// MARK: - RTCPeerConnectionDelegate

#if canImport(WebRTC)
extension WebRTCClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            let stateDescription: String
            switch stateChanged {
            case .stable: stateDescription = "stable"
            case .haveLocalOffer: stateDescription = "have-local-offer"
            case .haveLocalPrAnswer: stateDescription = "have-local-pranswer"
            case .haveRemoteOffer: stateDescription = "have-remote-offer"
            case .haveRemotePrAnswer: stateDescription = "have-remote-pranswer"
            case .closed: stateDescription = "closed"
            @unknown default: stateDescription = "unknown"
            }
            logger.info("Signaling state changed: \(stateDescription)")
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            logger.info("Added media stream: \(stream.streamId)")
            
            // Check for video tracks in the stream
            if let videoTrack = stream.videoTracks.first {
                logger.info("Found video track in stream")
                remoteVideoTrack = videoTrack
                delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
            }
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            logger.info("Removed media stream: \(stream.streamId)")
            
            if stream.videoTracks.contains(where: { $0 == remoteVideoTrack }) {
                remoteVideoTrack = nil
            }
        }
    }
    
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            logger.debug("Peer connection should negotiate (renegotiation needed)")
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            let stateDescription: String
            switch newState {
            case .new: stateDescription = "new"
            case .checking: stateDescription = "checking"
            case .connected: stateDescription = "connected"
            case .completed: stateDescription = "completed"
            case .failed: stateDescription = "failed"
            case .disconnected: stateDescription = "disconnected"
            case .closed: stateDescription = "closed"
            case .count: stateDescription = "count"
            @unknown default: stateDescription = "unknown"
            }
            logger.info("ICE connection state changed: \(stateDescription)")
            
            // Map ICE connection state to our ConnectionState
            switch newState {
            case .connected, .completed:
                updateState(.connected)
            case .disconnected:
                updateState(.disconnected)
            case .failed:
                updateState(.failed("ICE connection failed"))
                delegate?.webRTCClient(self, didReceiveError: .webRTCError("ICE connection failed"))
            case .closed:
                updateState(.closed)
            case .checking:
                updateState(.iceNegotiating)
            case .new:
                // Stay in current state
                break
            case .count:
                break
            @unknown default:
                break
            }
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in
            let stateDescription: String
            switch newState {
            case .new: stateDescription = "new"
            case .gathering: stateDescription = "gathering"
            case .complete: stateDescription = "complete"
            @unknown default: stateDescription = "unknown"
            }
            logger.info("ICE gathering state changed: \(stateDescription)")
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            logger.debug("Generated local ICE candidate: \(candidate.sdp)")
            
            let message = ICECandidateMessage(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
            
            // Notify delegate
            delegate?.webRTCClient(self, didGenerateLocalCandidate: message)
            
            // Send candidate to server via signaling client
            Task {
                do {
                    try await signalingClient.sendCandidate(message)
                    logger.debug("Sent ICE candidate to server")
                } catch {
                    logger.error("Failed to send ICE candidate: \(error.localizedDescription)")
                    // Don't treat this as a fatal error - trickle ICE may still work
                }
            }
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Task { @MainActor in
            logger.debug("Removed \(candidates.count) ICE candidates")
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            logger.info("Data channel opened: \(dataChannel.label)")
        }
    }
    
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        Task { @MainActor in
            logger.info("Added RTP receiver: \(rtpReceiver.receiverId)")
            
            // Check if this is a video track
            if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
                logger.info("Received remote video track via RTP receiver")
                remoteVideoTrack = videoTrack
                delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
            } else if rtpReceiver.track is RTCAudioTrack {
                logger.info("Received remote audio track via RTP receiver")
            }
        }
    }
}
#endif

// MARK: - Mock Support for Testing

extension WebRTCClient {
    /// Check if running in mock mode (WebRTC SDK not available)
    var isMockMode: Bool {
        #if canImport(WebRTC)
        return false
        #else
        return true
        #endif
    }
    
    /// Simulate receiving a video track (for testing without WebRTC SDK)
    func simulateVideoTrackReceived() {
        #if !canImport(WebRTC)
        logger.info("Simulating video track received (mock mode)")
        delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: "MockVideoTrack")
        #endif
    }
}
