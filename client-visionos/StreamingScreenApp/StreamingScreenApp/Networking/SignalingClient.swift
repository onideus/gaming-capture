//
//  SignalingClient.swift
//  StreamingScreenApp
//
//  Created for Phase 4: VisionOS Client WebRTC Integration
//

import Foundation
import os.log

/// Client for WebRTC signaling with the gateway server
///
/// This actor handles HTTP communication with the Go WebRTC Gateway for WebRTC signaling:
/// - Sending SDP offers and receiving answers
/// - Exchanging ICE candidates
/// - Health checks
///
/// Thread-safe by design as an actor.
actor SignalingClient {
    // MARK: - Properties
    
    private let config: AppConfig
    private let session: URLSession
    private var peerID: String?
    
    private let logger = Logger(subsystem: "com.streamingscreen.app", category: "SignalingClient")
    
    /// Callback for error reporting
    var onError: ((StreamingError) -> Void)?
    
    // MARK: - Initialization
    
    /// Initialize the signaling client with configuration
    /// - Parameter config: The app configuration containing server endpoints
    init(config: AppConfig) {
        self.config = config
        
        // Configure URLSession for low-latency signaling
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10.0
        sessionConfig.timeoutIntervalForResource = 30.0
        sessionConfig.waitsForConnectivity = false
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.session = URLSession(configuration: sessionConfig)
        
        logger.debug("SignalingClient initialized with gateway: \(config.gatewayURL.absoluteString)")
    }
    
    // MARK: - Public Methods
    
    /// Send SDP offer and receive answer
    /// - Parameter sdp: The SDP offer string
    /// - Returns: The SDP answer from the server
    /// - Throws: `StreamingError` if the request fails
    func sendOffer(_ sdp: String) async throws -> SDPAnswer {
        logger.info("Sending SDP offer to \(self.config.offerURL.absoluteString)")
        
        let offer = SDPOffer(sdp: sdp)
        var request = try createRequest(url: config.offerURL, body: offer)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type received")
                throw StreamingError.invalidResponse
            }
            
            // Extract peer ID from response header
            if let peerID = httpResponse.value(forHTTPHeaderField: "X-Peer-ID") {
                self.peerID = peerID
                logger.debug("Received peer ID: \(peerID)")
            }
            
            guard httpResponse.statusCode == 200 else {
                logger.error("Offer failed with status: \(httpResponse.statusCode)")
                try handleHTTPError(response: httpResponse, data: data)
                throw StreamingError.serverError(httpResponse.statusCode, "Offer failed")
            }
            
            let answer = try JSONDecoder().decode(SDPAnswer.self, from: data)
            logger.info("Received SDP answer, type: \(answer.type)")
            
            return answer
            
        } catch let error as StreamingError {
            onError?(error)
            throw error
        } catch let urlError as URLError {
            logger.error("Network error during offer: \(urlError.localizedDescription)")
            let streamingError = StreamingError.networkError(urlError)
            onError?(streamingError)
            throw streamingError
        } catch {
            logger.error("Unexpected error during offer: \(error.localizedDescription)")
            let streamingError = StreamingError.signalingFailed(error.localizedDescription)
            onError?(streamingError)
            throw streamingError
        }
    }
    
    /// Send ICE candidate to the server
    /// - Parameter candidate: The ICE candidate to send
    /// - Throws: `StreamingError` if the request fails or peer ID is not set
    func sendCandidate(_ candidate: ICECandidateMessage) async throws {
        guard let peerID = self.peerID else {
            logger.error("Cannot send candidate: not connected (no peer ID)")
            throw StreamingError.notConnected
        }
        
        logger.debug("Sending ICE candidate for peer: \(peerID)")
        
        var request = try createRequest(url: config.candidateURL, body: candidate)
        request.setValue(peerID, forHTTPHeaderField: "X-Peer-ID")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type received")
                throw StreamingError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                logger.error("Candidate failed with status: \(httpResponse.statusCode)")
                try handleHTTPError(response: httpResponse, data: data)
                throw StreamingError.serverError(httpResponse.statusCode, "Candidate failed")
            }
            
            // Optionally decode response to verify success
            if let candidateResponse = try? JSONDecoder().decode(ICECandidateResponse.self, from: data) {
                if candidateResponse.success {
                    logger.debug("ICE candidate accepted by server")
                } else {
                    logger.warning("ICE candidate was not accepted by server")
                }
            }
            
        } catch let error as StreamingError {
            onError?(error)
            throw error
        } catch let urlError as URLError {
            logger.error("Network error during candidate send: \(urlError.localizedDescription)")
            let streamingError = StreamingError.networkError(urlError)
            onError?(streamingError)
            throw streamingError
        } catch {
            logger.error("Unexpected error during candidate send: \(error.localizedDescription)")
            let streamingError = StreamingError.signalingFailed(error.localizedDescription)
            onError?(streamingError)
            throw streamingError
        }
    }
    
    /// Check server health
    /// - Returns: Health response from server
    /// - Throws: `StreamingError` if the health check fails
    func checkHealth() async throws -> HealthResponse {
        logger.debug("Checking server health at \(self.config.healthURL.absoluteString)")
        
        var request = URLRequest(url: config.healthURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type received")
                throw StreamingError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                logger.error("Health check failed with status: \(httpResponse.statusCode)")
                try handleHTTPError(response: httpResponse, data: data)
                throw StreamingError.serverError(httpResponse.statusCode, "Health check failed")
            }
            
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            logger.info("Server health: \(health.status), peers: \(health.peers), uptime: \(health.uptime)")
            
            return health
            
        } catch let error as StreamingError {
            onError?(error)
            throw error
        } catch let urlError as URLError {
            logger.error("Network error during health check: \(urlError.localizedDescription)")
            let streamingError = StreamingError.networkError(urlError)
            onError?(streamingError)
            throw streamingError
        } catch {
            logger.error("Unexpected error during health check: \(error.localizedDescription)")
            let streamingError = StreamingError.signalingFailed(error.localizedDescription)
            onError?(streamingError)
            throw streamingError
        }
    }
    
    /// Get the current peer ID (set after successful offer)
    /// - Returns: The peer ID if connected, nil otherwise
    func getPeerID() -> String? {
        return peerID
    }
    
    /// Reset the client state
    ///
    /// Call this when disconnecting or preparing for a new connection.
    func reset() {
        logger.debug("Resetting SignalingClient state")
        peerID = nil
    }
    
    // MARK: - Private Methods
    
    /// Create a POST request with JSON body
    /// - Parameters:
    ///   - url: The URL for the request
    ///   - body: The encodable body to serialize as JSON
    /// - Returns: A configured URLRequest
    /// - Throws: Encoding error if the body cannot be serialized
    private func createRequest(url: URL, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)
        
        return request
    }
    
    /// Perform a request and decode response
    /// - Parameter request: The URL request to perform
    /// - Returns: The decoded response
    /// - Throws: `StreamingError` if the request or decoding fails
    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            try handleHTTPError(response: httpResponse, data: data)
            throw StreamingError.serverError(httpResponse.statusCode, "Request failed")
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// Handle HTTP errors by attempting to decode error response
    /// - Parameters:
    ///   - response: The HTTP response
    ///   - data: The response data
    /// - Throws: `StreamingError` with appropriate error message
    private func handleHTTPError(response: HTTPURLResponse, data: Data) throws {
        // Try to decode error response from server
        if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            let message = errorResponse.message ?? errorResponse.error
            logger.error("Server error response: \(message)")
            throw StreamingError.serverError(response.statusCode, message)
        }
        
        // Fall back to generic HTTP status description
        let statusDescription = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        logger.error("HTTP error: \(response.statusCode) - \(statusDescription)")
        throw StreamingError.serverError(response.statusCode, statusDescription)
    }
}

// MARK: - Convenience Extensions

extension SignalingClient {
    /// Check if the client has an active connection (has peer ID)
    var isConnected: Bool {
        get async {
            return peerID != nil
        }
    }
    
    /// Create a signaling client with default configuration
    static func withDefaultConfig() -> SignalingClient {
        return SignalingClient(config: .default)
    }
}
