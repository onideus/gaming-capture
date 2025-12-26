//
//  ConnectionState.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation

/// Represents the current state of the WebRTC connection
enum ConnectionState: Equatable {
    /// Not connected, ready to connect
    case disconnected
    
    /// Currently establishing connection
    case connecting
    
    /// Signaling in progress (SDP exchange)
    case signaling
    
    /// ICE gathering/checking
    case iceNegotiating
    
    /// Connected and streaming
    case connected
    
    /// Connection failed with error
    case failed(String)
    
    /// Manually disconnected
    case closed
    
    /// Whether the connection is active
    var isActive: Bool {
        switch self {
        case .connecting, .signaling, .iceNegotiating, .connected:
            return true
        default:
            return false
        }
    }
    
    /// Whether we're fully connected
    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
    
    /// Human-readable status text
    var statusText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .signaling:
            return "Signaling..."
        case .iceNegotiating:
            return "Negotiating..."
        case .connected:
            return "Connected"
        case .failed(let error):
            return "Failed: \(error)"
        case .closed:
            return "Closed"
        }
    }
    
    /// SF Symbol name for the state
    var iconName: String {
        switch self {
        case .disconnected, .closed:
            return "wifi.slash"
        case .connecting, .signaling, .iceNegotiating:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "wifi"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
