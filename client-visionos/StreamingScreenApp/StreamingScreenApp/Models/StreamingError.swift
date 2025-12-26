//
//  StreamingError.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation

/// Errors that can occur during streaming
enum StreamingError: LocalizedError {
    case connectionFailed(String)
    case signalingFailed(String)
    case webRTCError(String)
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse
    case timeout
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .signalingFailed(let reason):
            return "Signaling failed: \(reason)"
        case .webRTCError(let reason):
            return "WebRTC error: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .timeout:
            return "Connection timed out"
        case .notConnected:
            return "Not connected to server"
        }
    }
}
