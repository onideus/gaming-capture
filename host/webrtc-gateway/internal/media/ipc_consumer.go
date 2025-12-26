package media

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
)

// IPCConsumer listens for encoded frames from the capture service
type IPCConsumer struct {
	socketPath string
	listener   net.Listener
	conn       net.Conn

	Frames chan EncodedFrame

	mu       sync.Mutex
	running  bool
	stopChan chan struct{}
}

// NewIPCConsumer creates a new IPC consumer
func NewIPCConsumer(socketPath string) *IPCConsumer {
	return &IPCConsumer{
		socketPath: socketPath,
		Frames:     make(chan EncodedFrame, 120), // buffer ~2 seconds at 60fps
		stopChan:   make(chan struct{}),
	}
}

// Start begins listening for connections and reading frames
func (c *IPCConsumer) Start() error {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return fmt.Errorf("already running")
	}
	c.running = true
	c.mu.Unlock()

	// Remove existing socket file if present
	os.Remove(c.socketPath)

	// Create Unix socket listener
	listener, err := net.Listen("unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("failed to listen on %s: %w", c.socketPath, err)
	}
	c.listener = listener

	log.Printf("IPC listening on %s", c.socketPath)

	// Accept connections in a loop
	go c.acceptLoop()

	return nil
}

func (c *IPCConsumer) acceptLoop() {
	for {
		select {
		case <-c.stopChan:
			return
		default:
		}

		conn, err := c.listener.Accept()
		if err != nil {
			select {
			case <-c.stopChan:
				return
			default:
				log.Printf("IPC accept error: %v", err)
				continue
			}
		}

		log.Printf("IPC client connected from capture service")

		c.mu.Lock()
		// Close previous connection if any
		if c.conn != nil {
			c.conn.Close()
		}
		c.conn = conn
		c.mu.Unlock()

		// Handle this connection
		c.handleConnection(conn)
	}
}

func (c *IPCConsumer) handleConnection(conn net.Conn) {
	defer func() {
		conn.Close()
		c.mu.Lock()
		if c.conn == conn {
			c.conn = nil
		}
		c.mu.Unlock()
		log.Printf("IPC client disconnected")
	}()

	header := make([]byte, HeaderSize)
	frameCount := 0
	keyframeCount := 0

	for {
		select {
		case <-c.stopChan:
			return
		default:
		}

		// Read header
		_, err := io.ReadFull(conn, header)
		if err != nil {
			if err != io.EOF {
				log.Printf("IPC header read error: %v", err)
			}
			return
		}

		// Parse header
		frameType := FrameType(header[0])
		flags := FrameFlags(header[1])
		pts := int64(binary.LittleEndian.Uint64(header[2:10]))
		length := binary.LittleEndian.Uint32(header[10:14])

		isKeyFrame := flags&FlagKeyframe != 0

		// Sanity check on length
		if length > 10*1024*1024 { // 10MB max frame size
			log.Printf("IPC frame too large: %d bytes", length)
			return
		}

		// Read payload
		payload := make([]byte, length)
		_, err = io.ReadFull(conn, payload)
		if err != nil {
			log.Printf("IPC payload read error: %v", err)
			return
		}

		frame := EncodedFrame{
			Type:       frameType,
			IsKeyFrame: isKeyFrame,
			PTS:        pts,
			Data:       payload,
		}

		// Send to channel (non-blocking)
		select {
		case c.Frames <- frame:
			frameCount++
			if isKeyFrame {
				keyframeCount++
			}
			// Log periodically
			if frameCount%300 == 0 { // every 5 seconds at 60fps
				log.Printf("IPC received %d frames (%d keyframes), latest: %s %d bytes",
					frameCount, keyframeCount, frameType, length)
			}
		default:
			// Channel full, drop frame
			log.Printf("IPC frame dropped (channel full)")
		}
	}
}

// Stop shuts down the IPC consumer
func (c *IPCConsumer) Stop() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.running {
		return nil
	}

	c.running = false
	close(c.stopChan)

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}

	if c.listener != nil {
		c.listener.Close()
		c.listener = nil
	}

	// Remove socket file
	os.Remove(c.socketPath)

	close(c.Frames)

	log.Printf("IPC consumer stopped")
	return nil
}

// IsRunning returns whether the consumer is running
func (c *IPCConsumer) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running
}
