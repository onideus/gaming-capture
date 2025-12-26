//
//  AppConfig.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation

/// Application configuration for the streaming client
struct AppConfig: Codable, Equatable {
    /// Gateway server host (IP or hostname)
    var serverHost: String
    
    /// Gateway server port
    var serverPort: Int
    
    /// Whether to auto-connect on launch
    var autoConnect: Bool
    
    /// Preferred video quality
    var videoQuality: VideoQuality
    
    /// Enable debug logging
    var debugLogging: Bool
    
    /// Default configuration
    static let `default` = AppConfig(
        serverHost: "192.168.1.100",
        serverPort: 8080,
        autoConnect: false,
        videoQuality: .high,
        debugLogging: false
    )
    
    /// Base URL for the gateway
    var gatewayURL: URL {
        URL(string: "http://\(serverHost):\(serverPort)")!
    }
    
    /// WebRTC offer endpoint
    var offerURL: URL {
        gatewayURL.appendingPathComponent("webrtc/offer")
    }
    
    /// ICE candidate endpoint
    var candidateURL: URL {
        gatewayURL.appendingPathComponent("webrtc/candidate")
    }
    
    /// Health check endpoint
    var healthURL: URL {
        gatewayURL.appendingPathComponent("webrtc/health")
    }
}

/// Video quality presets
enum VideoQuality: String, Codable, CaseIterable {
    case low = "low"        // 720p
    case medium = "medium"  // 1080p
    case high = "high"      // 4K
    
    var displayName: String {
        switch self {
        case .low: return "720p"
        case .medium: return "1080p"
        case .high: return "4K"
        }
    }
}
