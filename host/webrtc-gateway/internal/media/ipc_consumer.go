// Package media handles media ingestion and pipeline management.
package media

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
)

// MessageType represents the type of IPC message
type MessageType byte

const (
	MessageTypeVideo    MessageType = 0x01
	MessageTypeAudio    MessageType = 0x02
	MessageTypeMetadata MessageType = 0x03
)

// String returns a human-readable name for the message type
func (m MessageType) String() string {
	switch m {
	case MessageTypeVideo:
		return "video"
	case MessageTypeAudio:
		return "audio"
	case MessageTypeMetadata:
		return "metadata"
	default:
		return fmt.Sprintf("unknown(0x%02x)", byte(m))
	}
}

// VideoFrame represents an encoded video frame from the capture service
type VideoFrame struct {
	PTS        int64  // Presentation timestamp in nanoseconds
	DTS        int64  // Decode timestamp in nanoseconds
	IsKeyframe bool   // True if this is a keyframe
	Width      int    // Frame width
	Height     int    // Frame height
	Codec      string // "h264" or "hevc"
	Data       []byte // Encoded frame data (NAL units)
	ReceivedAt time.Time
}

// AudioFrame represents PCM audio samples
type AudioFrame struct {
	PTS         int64  // Presentation timestamp in nanoseconds
	SampleRate  int    // e.g., 48000
	Channels    int    // e.g., 2 for stereo
	SampleCount int    // Number of samples
	Data        []byte // Raw PCM samples (16-bit signed, interleaved)
	ReceivedAt  time.Time
}

// StreamMetadata contains stream configuration from capture service
type StreamMetadata struct {
	VideoWidth    int    `json:"video_width"`
	VideoHeight   int    `json:"video_height"`
	VideoCodec    string `json:"video_codec"`
	VideoFPS      int    `json:"video_fps"`
	AudioRate     int    `json:"audio_sample_rate"`
	AudioChannels int    `json:"audio_channels"`
}

// videoFrameMetadata is the JSON structure for video frame metadata
type videoFrameMetadata struct {
	PTS      int64  `json:"pts"`
	DTS      int64  `json:"dts"`
	Keyframe bool   `json:"keyframe"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Codec    string `json:"codec"`
}

// audioFrameMetadata is the JSON structure for audio frame metadata
type audioFrameMetadata struct {
	PTS         int64 `json:"pts"`
	SampleRate  int   `json:"sample_rate"`
	Channels    int   `json:"channels"`
	SampleCount int   `json:"sample_count"`
}

// IPCConsumerConfig configures the IPC consumer
type IPCConsumerConfig struct {
	SocketPath      string
	VideoBufferSize int           // Channel buffer size, default 30
	AudioBufferSize int           // Channel buffer size, default 60
	ReconnectDelay  time.Duration // Delay between reconnect attempts
}

// DefaultIPCConsumerConfig returns sensible defaults for IPC consumer config
func DefaultIPCConsumerConfig() IPCConsumerConfig {
	return IPCConsumerConfig{
		SocketPath:      "/tmp/gaming-capture.sock",
		VideoBufferSize: 30,
		AudioBufferSize: 60,
		ReconnectDelay:  time.Second,
	}
}

// IPCConsumer listens on a Unix socket and reads frames from the capture service
type IPCConsumer struct {
	socketPath string
	listener   net.Listener
	conn       net.Conn
	logger     zerolog.Logger

	videoFrames chan VideoFrame
	audioFrames chan AudioFrame
	metadata    chan StreamMetadata
	errors      chan error

	mu        sync.RWMutex
	connected bool
	listening bool

	ctx    context.Context
	cancel context.CancelFunc

	// Statistics
	videoFrameCount atomic.Uint64
	audioFrameCount atomic.Uint64
	bytesReceived   atomic.Uint64
	lastStatsTime   time.Time
	statsInterval   time.Duration

	// For calculating per-interval rates
	lastVideoFrameCount uint64
	lastAudioFrameCount uint64
	lastBytesReceived   uint64
}

// NewIPCConsumer creates a new IPC consumer
func NewIPCConsumer(cfg IPCConsumerConfig, logger zerolog.Logger) *IPCConsumer {
	// Apply defaults for zero values
	if cfg.VideoBufferSize <= 0 {
		cfg.VideoBufferSize = 30
	}
	if cfg.AudioBufferSize <= 0 {
		cfg.AudioBufferSize = 60
	}

	return &IPCConsumer{
		socketPath:    cfg.SocketPath,
		logger:        logger.With().Str("component", "ipc_consumer").Logger(),
		videoFrames:   make(chan VideoFrame, cfg.VideoBufferSize),
		audioFrames:   make(chan AudioFrame, cfg.AudioBufferSize),
		metadata:      make(chan StreamMetadata, 4),
		errors:        make(chan error, 16),
		statsInterval: 5 * time.Second,
	}
}

// Start begins listening on the Unix socket for capture service connections
// Returns immediately; frames are sent to channels
func (c *IPCConsumer) Start(ctx context.Context) error {
	c.mu.Lock()
	if c.listening {
		c.mu.Unlock()
		return errors.New("consumer already started")
	}
	c.ctx, c.cancel = context.WithCancel(ctx)
	c.mu.Unlock()

	// Remove stale socket file if it exists
	if err := os.Remove(c.socketPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove stale socket: %w", err)
	}

	// Start listening on Unix socket
	listener, err := net.Listen("unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("failed to listen on socket: %w", err)
	}

	c.mu.Lock()
	c.listener = listener
	c.listening = true
	c.mu.Unlock()

	c.lastStatsTime = time.Now()

	// Start the accept loop in a goroutine
	go c.acceptLoop()

	c.logger.Info().
		Str("socket_path", c.socketPath).
		Msg("IPC consumer listening for connections")

	return nil
}

// Stop stops listening and disconnects any active connection
func (c *IPCConsumer) Stop() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.cancel != nil {
		c.cancel()
	}

	var errs []error

	// Close active connection
	if c.conn != nil {
		if err := c.conn.Close(); err != nil {
			errs = append(errs, err)
		}
		c.conn = nil
	}
	c.connected = false

	// Close listener
	if c.listener != nil {
		if err := c.listener.Close(); err != nil {
			errs = append(errs, err)
		}
		c.listener = nil
	}
	c.listening = false

	// Clean up socket file
	os.Remove(c.socketPath)

	c.logger.Info().Msg("IPC consumer stopped")

	if len(errs) > 0 {
		return errs[0]
	}
	return nil
}

// VideoFrames returns the channel for receiving video frames
func (c *IPCConsumer) VideoFrames() <-chan VideoFrame {
	return c.videoFrames
}

// AudioFrames returns the channel for receiving audio frames
func (c *IPCConsumer) AudioFrames() <-chan AudioFrame {
	return c.audioFrames
}

// Metadata returns the channel for receiving stream metadata
func (c *IPCConsumer) Metadata() <-chan StreamMetadata {
	return c.metadata
}

// Errors returns the channel for receiving errors
func (c *IPCConsumer) Errors() <-chan error {
	return c.errors
}

// IsConnected returns true if connected to the socket
func (c *IPCConsumer) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

// Stats returns current statistics
func (c *IPCConsumer) Stats() (videoFrames, audioFrames, bytesReceived uint64) {
	return c.videoFrameCount.Load(), c.audioFrameCount.Load(), c.bytesReceived.Load()
}

// acceptLoop waits for capture service connections and handles them
func (c *IPCConsumer) acceptLoop() {
	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		c.mu.RLock()
		listener := c.listener
		c.mu.RUnlock()

		if listener == nil {
			return
		}

		// Accept a connection (blocks until connection or listener closed)
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-c.ctx.Done():
				return
			default:
				// Check if it's a temporary error
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					continue
				}
				c.logger.Warn().Err(err).Msg("Accept error")
				select {
				case c.errors <- fmt.Errorf("accept failed: %w", err):
				default:
				}
				continue
			}
		}

		c.logger.Info().Msg("Capture service connected")

		// Close any existing connection (only one client at a time)
		c.mu.Lock()
		if c.conn != nil {
			c.conn.Close()
		}
		c.conn = conn
		c.connected = true
		c.mu.Unlock()

		// Read frames until disconnected
		if err := c.readLoop(); err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				c.logger.Warn().
					Err(err).
					Msg("Read loop error")

				select {
				case c.errors <- fmt.Errorf("read error: %w", err):
				default:
				}
			}
		}

		// Client disconnected
		c.mu.Lock()
		if c.conn != nil {
			c.conn.Close()
			c.conn = nil
		}
		c.connected = false
		c.mu.Unlock()

		c.logger.Info().Msg("Capture service disconnected, waiting for reconnection")
	}
}

// readLoop continuously reads frames from socket
func (c *IPCConsumer) readLoop() error {
	for {
		select {
		case <-c.ctx.Done():
			return c.ctx.Err()
		default:
		}

		// Set read deadline to prevent blocking forever
		c.mu.RLock()
		conn := c.conn
		c.mu.RUnlock()

		if conn == nil {
			return errors.New("connection closed")
		}

		if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return err
		}

		// Parse a single message
		msgType, jsonData, payload, err := c.parseMessage(conn)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				// Timeout is OK, just continue to check context
				c.logStats()
				continue
			}
			return err
		}

		// Track bytes received
		c.bytesReceived.Add(uint64(1 + 4 + len(jsonData) + len(payload)))

		// Process based on message type
		switch msgType {
		case MessageTypeVideo:
			frame, err := c.parseVideoFrame(jsonData, payload)
			if err != nil {
				c.logger.Warn().Err(err).Msg("Failed to parse video frame")
				continue
			}

			// Send to channel (non-blocking to avoid backpressure issues)
			select {
			case c.videoFrames <- frame:
				c.videoFrameCount.Add(1)
			default:
				c.logger.Warn().Msg("Video frame channel full, dropping frame")
			}

		case MessageTypeAudio:
			frame, err := c.parseAudioFrame(jsonData, payload)
			if err != nil {
				c.logger.Warn().Err(err).Msg("Failed to parse audio frame")
				continue
			}

			select {
			case c.audioFrames <- frame:
				c.audioFrameCount.Add(1)
			default:
				c.logger.Warn().Msg("Audio frame channel full, dropping frame")
			}

		case MessageTypeMetadata:
			meta, err := c.parseStreamMetadata(jsonData)
			if err != nil {
				c.logger.Warn().Err(err).Msg("Failed to parse stream metadata")
				continue
			}

			c.logger.Info().
				Int("video_width", meta.VideoWidth).
				Int("video_height", meta.VideoHeight).
				Str("video_codec", meta.VideoCodec).
				Int("video_fps", meta.VideoFPS).
				Int("audio_rate", meta.AudioRate).
				Int("audio_channels", meta.AudioChannels).
				Msg("Received stream metadata")

			select {
			case c.metadata <- meta:
			default:
				c.logger.Warn().Msg("Metadata channel full, dropping metadata")
			}

		default:
			c.logger.Warn().
				Stringer("type", msgType).
				Msg("Unknown message type")
		}

		c.logStats()
	}
}

// parseMessage parses a single message from the stream
// Protocol: [1 byte: type] [4 bytes: length (big-endian)] [JSON metadata] [binary payload]
func (c *IPCConsumer) parseMessage(r io.Reader) (MessageType, []byte, []byte, error) {
	// Read message type (1 byte)
	typeBuf := make([]byte, 1)
	if _, err := io.ReadFull(r, typeBuf); err != nil {
		return 0, nil, nil, err
	}
	msgType := MessageType(typeBuf[0])

	// Read length (4 bytes, big-endian)
	lenBuf := make([]byte, 4)
	if _, err := io.ReadFull(r, lenBuf); err != nil {
		return 0, nil, nil, err
	}
	totalLen := binary.BigEndian.Uint32(lenBuf)

	// Sanity check length (max 100MB)
	if totalLen > 100*1024*1024 {
		return 0, nil, nil, fmt.Errorf("message too large: %d bytes", totalLen)
	}

	// Read the combined JSON + payload data
	data := make([]byte, totalLen)
	if _, err := io.ReadFull(r, data); err != nil {
		return 0, nil, nil, err
	}

	// Find the JSON/payload boundary
	// JSON is null-terminated or we find the closing brace
	jsonEnd := c.findJSONEnd(data)
	if jsonEnd < 0 {
		return 0, nil, nil, errors.New("could not find JSON boundary in message")
	}

	jsonData := data[:jsonEnd]
	var payload []byte
	// Skip past the null terminator (if present) to get payload
	payloadStart := jsonEnd
	if payloadStart < len(data) && data[payloadStart] == 0 {
		payloadStart++ // Skip the null terminator
	}
	if payloadStart < len(data) {
		payload = data[payloadStart:]
	}

	return msgType, jsonData, payload, nil
}

// findJSONEnd finds the end of the JSON portion in the data
// Returns the index of the byte AFTER JSON (the null terminator or first byte of payload)
func (c *IPCConsumer) findJSONEnd(data []byte) int {
	// Strategy 1: Look for null terminator after JSON
	// Return the index OF the null byte so jsonData excludes it
	for i, b := range data {
		if b == 0 {
			return i
		}
	}

	// Strategy 2: Find balanced braces
	depth := 0
	inString := false
	escaped := false

	for i, b := range data {
		if escaped {
			escaped = false
			continue
		}

		if b == '\\' && inString {
			escaped = true
			continue
		}

		if b == '"' {
			inString = !inString
			continue
		}

		if inString {
			continue
		}

		if b == '{' {
			depth++
		} else if b == '}' {
			depth--
			if depth == 0 {
				return i + 1
			}
		}
	}

	return -1
}

// parseVideoFrame parses JSON metadata for video frame
func (c *IPCConsumer) parseVideoFrame(jsonData, payload []byte) (VideoFrame, error) {
	var meta videoFrameMetadata
	if err := json.Unmarshal(jsonData, &meta); err != nil {
		return VideoFrame{}, fmt.Errorf("failed to parse video metadata: %w", err)
	}

	return VideoFrame{
		PTS:        meta.PTS,
		DTS:        meta.DTS,
		IsKeyframe: meta.Keyframe,
		Width:      meta.Width,
		Height:     meta.Height,
		Codec:      meta.Codec,
		Data:       payload,
		ReceivedAt: time.Now(),
	}, nil
}

// parseAudioFrame parses JSON metadata for audio frame
func (c *IPCConsumer) parseAudioFrame(jsonData, payload []byte) (AudioFrame, error) {
	var meta audioFrameMetadata
	if err := json.Unmarshal(jsonData, &meta); err != nil {
		return AudioFrame{}, fmt.Errorf("failed to parse audio metadata: %w", err)
	}

	return AudioFrame{
		PTS:         meta.PTS,
		SampleRate:  meta.SampleRate,
		Channels:    meta.Channels,
		SampleCount: meta.SampleCount,
		Data:        payload,
		ReceivedAt:  time.Now(),
	}, nil
}

// parseStreamMetadata parses stream configuration metadata
func (c *IPCConsumer) parseStreamMetadata(jsonData []byte) (StreamMetadata, error) {
	var meta StreamMetadata
	if err := json.Unmarshal(jsonData, &meta); err != nil {
		return StreamMetadata{}, fmt.Errorf("failed to parse stream metadata: %w", err)
	}
	return meta, nil
}

// logStats logs periodic statistics
func (c *IPCConsumer) logStats() {
	now := time.Now()
	if now.Sub(c.lastStatsTime) < c.statsInterval {
		return
	}

	elapsed := now.Sub(c.lastStatsTime).Seconds()
	videoFrames := c.videoFrameCount.Load()
	audioFrames := c.audioFrameCount.Load()
	bytes := c.bytesReceived.Load()

	// Calculate frames/bytes received during this interval
	videoFramesDelta := videoFrames - c.lastVideoFrameCount
	audioFramesDelta := audioFrames - c.lastAudioFrameCount
	bytesDelta := bytes - c.lastBytesReceived

	c.logger.Info().
		Float64("video_fps", float64(videoFramesDelta)/elapsed).
		Float64("audio_fps", float64(audioFramesDelta)/elapsed).
		Float64("bytes_per_sec", float64(bytesDelta)/elapsed).
		Uint64("total_video_frames", videoFrames).
		Uint64("total_audio_frames", audioFrames).
		Uint64("total_bytes", bytes).
		Msg("IPC consumer statistics")

	// Update last counts for next interval
	c.lastVideoFrameCount = videoFrames
	c.lastAudioFrameCount = audioFrames
	c.lastBytesReceived = bytes
	c.lastStatsTime = now
}

// Legacy types for backward compatibility

// Frame represents an encoded video frame received from the capture service.
// Deprecated: Use VideoFrame instead
type Frame struct {
	// Data contains the encoded frame bytes (H.264 or HEVC NAL units)
	Data []byte

	// Timestamp is the presentation timestamp in nanoseconds
	Timestamp int64

	// IsKeyframe indicates if this is an I-frame
	IsKeyframe bool

	// Codec indicates the video codec ("h264" or "hevc")
	Codec string
}

// FrameHandler is a callback function for processing received frames.
// Deprecated: Use VideoFrames() channel instead
type FrameHandler func(frame *Frame)

// ToFrame converts a VideoFrame to the legacy Frame type
func (vf *VideoFrame) ToFrame() *Frame {
	return &Frame{
		Data:       vf.Data,
		Timestamp:  vf.PTS,
		IsKeyframe: vf.IsKeyframe,
		Codec:      vf.Codec,
	}
}
