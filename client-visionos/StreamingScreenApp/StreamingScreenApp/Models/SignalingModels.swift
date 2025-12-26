//
//  SignalingModels.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation

/// SDP offer sent to the server
struct SDPOffer: Codable {
    let sdp: String
    let type: String  // Always "offer"
    
    init(sdp: String) {
        self.sdp = sdp
        self.type = "offer"
    }
}

/// SDP answer received from the server
struct SDPAnswer: Codable {
    let sdp: String
    let type: String  // Always "answer"
}

/// ICE candidate to send to the server
struct ICECandidateMessage: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

/// Response when posting an ICE candidate
struct ICECandidateResponse: Codable {
    let success: Bool
    let peerID: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case peerID = "peer_id"
    }
}

/// Health check response from the server
struct HealthResponse: Codable {
    let status: String
    let peers: Int
    let uptime: String
}

/// Generic error response from the server
struct ErrorResponse: Codable {
    let error: String
    let message: String?
}
