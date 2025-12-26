//
//  AppModel.swift
//  StreamingScreenApp
//
//  Created by Zach Martin on 12/25/25.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
    
    // MARK: - Connection State
    
    /// Current WebRTC connection state
    var connectionState: ConnectionState = .disconnected
    
    // MARK: - Configuration
    
    /// Application configuration
    var config: AppConfig = .default
    
    // MARK: - Session Info
    
    /// Peer ID from server (for ICE candidates)
    var peerID: String?
    
    // MARK: - Stats
    
    /// Time of last received frame
    var lastFrameTime: Date?
    
    /// Total frames received this session
    var framesReceived: Int = 0
    
    // MARK: - Methods
    
    /// Update connection state
    func updateConnectionState(_ state: ConnectionState) {
        self.connectionState = state
    }
    
    /// Reset stats for new session
    func resetStats() {
        lastFrameTime = nil
        framesReceived = 0
        peerID = nil
    }
    
    /// Record a received frame
    func recordFrame() {
        lastFrameTime = Date()
        framesReceived += 1
    }
    
    /// Calculate frames per second based on recent frame rate
    var estimatedFPS: Double {
        guard framesReceived > 0, let lastFrame = lastFrameTime else {
            return 0
        }
        // This is a simple estimate - could be improved with a rolling window
        let elapsed = Date().timeIntervalSince(lastFrame)
        guard elapsed > 0 else { return 0 }
        return min(Double(framesReceived) / elapsed, 120) // Cap at 120 FPS
    }
}
