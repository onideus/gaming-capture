# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Low-latency 4K streaming system from Elgato 4K X capture card (connected to ROG Ally X) through macOS to Apple Vision Pro. Target: ≤60ms glass-to-glass latency over local LAN.

## Architecture

Three main components communicate via IPC and WebRTC:

1. **Host Capture Service (Swift)** - `host/capture-service/`
   - Captures video/audio from Elgato via AVFoundation
   - Hardware encodes via VideoToolbox (H.264/HEVC)
   - Sends encoded frames to WebRTC Gateway via Unix domain socket

2. **Host WebRTC Gateway (Go + Pion)** - `host/webrtc-gateway/`
   - Consumes encoded frames from IPC socket
   - Wraps frames into RTP packets via Pion WebRTC
   - Exposes HTTP signaling endpoints for session setup

3. **Vision Pro Client (SwiftUI/RealityKit)** - `client-visionos/`
   - WebRTC client using iOS WebRTC SDK (libwebrtc)
   - Hardware decodes and renders as floating screen in immersive space

### Data Flow

```
ROG Ally X → HDMI → Elgato 4K X → USB → macOS Capture Service
→ Unix Socket IPC → Go WebRTC Gateway → WebRTC/RTP → Vision Pro Client
```

### IPC Protocol (Unix Domain Socket)

Frame format: `[1-byte type][4-byte length BE][JSON metadata][binary payload]`
- Type 0x01: encoded video frame
- Type 0x02: raw PCM audio frame

### Signaling API (HTTP)

- `POST /webrtc/offer` - SDP offer/answer exchange
- `POST /webrtc/candidate` - ICE candidate trickle

## Build Commands

```bash
# Swift Capture Service (macOS)
cd host/capture-service
swift build

# Go WebRTC Gateway
cd host/webrtc-gateway
go build ./cmd/webrtc-gateway

# VisionOS Client - open in Xcode
open client-visionos/StreamingScreenApp.xcodeproj
```

## Key Technical Decisions

- **Video Codec**: H.264 for initial compatibility, HEVC later
- **Bitrate**: 15-25 Mbps for 1080p60, higher for 4K
- **Keyframe interval**: 1-2 seconds
- **ICE**: LAN-only (no STUN/TURN needed)
- **No simulcast**: single video stream only
