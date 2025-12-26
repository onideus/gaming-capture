// Package main provides the entry point for the WebRTC Gateway.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	"github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/config"
	mediapkg "github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/media"
	"github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/signaling"
	webrtcpkg "github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/webrtc"
)

func main() {
	// Print startup banner
	printBanner()

	// Load configuration
	fmt.Println("Loading configuration...")
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading configuration: %v\n", err)
		os.Exit(1)
	}

	// Setup logging
	logger := setupLogging(cfg)

	// Log configuration summary
	logger.Info().
		Str("listen_addr", cfg.HTTPListenAddr).
		Str("video_codec", cfg.VideoCodec).
		Bool("synthetic", cfg.UseSynthetic).
		Int("max_bitrate_kbps", cfg.MaxBitrateKbps).
		Msg("Configuration loaded")

	// Create WebRTC PeerManager
	logger.Info().Msg("Creating WebRTC peer manager...")
	peerConfig := webrtcpkg.PeerConfig{
		VideoCodec:     cfg.VideoCodec,
		AudioCodec:     "opus",
		MaxBitrateKbps: cfg.MaxBitrateKbps,
		ICEServers:     []webrtc.ICEServer{}, // Empty for local testing
	}

	peerManager, err := webrtcpkg.NewPeerManager(peerConfig, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to create peer manager")
	}

	// Set up peer connection callbacks
	peerManager.SetOnPeerConnected(func(peerID string) {
		logger.Info().Str("peer_id", peerID).Msg("Peer connected")
	})
	peerManager.SetOnPeerDisconnected(func(peerID string) {
		logger.Info().Str("peer_id", peerID).Msg("Peer disconnected")
	})

	logger.Info().Msg("Peer manager created")

	// Create Pipeline
	var pipelineOpts []mediapkg.PipelineOption
	if cfg.UseSynthetic {
		logger.Info().Msg("Creating media pipeline (synthetic mode)...")
		syntheticConfig := mediapkg.SyntheticConfig{
			Width:     cfg.SyntheticWidth,
			Height:    cfg.SyntheticHeight,
			FrameRate: cfg.SyntheticFPS,
			Pattern:   mediapkg.PatternType(cfg.SyntheticPattern),
		}
		pipelineOpts = append(pipelineOpts, mediapkg.WithSyntheticVideo(syntheticConfig))
	} else {
		logger.Info().Msg("Creating media pipeline (IPC mode)...")
	}

	pipeline := mediapkg.NewPipeline(cfg, logger, pipelineOpts...)

	if cfg.UseSynthetic {
		logger.Info().
			Int("width", cfg.SyntheticWidth).
			Int("height", cfg.SyntheticHeight).
			Int("fps", cfg.SyntheticFPS).
			Str("pattern", mediapkg.PatternType(cfg.SyntheticPattern).String()).
			Msg("Pipeline created")
	} else {
		logger.Info().
			Str("socket", cfg.IPCSocketPath).
			Msg("Pipeline created")
	}

	// Create HTTP Signaling Server
	logger.Info().Msg("Creating signaling server...")
	serverConfig := signaling.ServerConfig{
		ListenAddr:     cfg.HTTPListenAddr,
		AllowedOrigins: cfg.AllowedOrigins,
		ReadTimeout:    30 * time.Second,
		WriteTimeout:   30 * time.Second,
	}
	httpServer := signaling.NewServer(serverConfig, peerManager, logger)

	// Create main context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start Pipeline
	logger.Info().Msg("Starting pipeline...")
	if err := pipeline.Start(ctx); err != nil {
		logger.Fatal().Err(err).Msg("Failed to start pipeline")
	}
	logger.Info().Msg("Pipeline started")

	// Start video distribution goroutine
	startVideoDistribution(ctx, pipeline, peerManager, logger)

	// Start HTTP server
	logger.Info().Msg("Starting HTTP signaling server...")
	if err := httpServer.Start(); err != nil {
		logger.Fatal().Err(err).Msg("Failed to start HTTP server")
	}

	// Print ready message
	printReadyMessage(cfg)

	// Wait for shutdown signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan

	logger.Info().Str("signal", sig.String()).Msg("Received shutdown signal")

	// Create shutdown context with timeout
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	// Stop HTTP server first
	logger.Info().Msg("Shutting down HTTP server...")
	if err := httpServer.Stop(shutdownCtx); err != nil {
		logger.Error().Err(err).Msg("Error stopping HTTP server")
	}
	logger.Info().Msg("HTTP server stopped")

	// Cancel main context to stop pipeline
	cancel()

	// Stop pipeline
	logger.Info().Msg("Stopping pipeline...")
	if err := pipeline.Stop(); err != nil {
		logger.Error().Err(err).Msg("Error stopping pipeline")
	}
	logger.Info().Msg("Pipeline stopped")

	// Close peer manager
	logger.Info().Msg("Closing peer manager...")
	if err := peerManager.Close(); err != nil {
		logger.Error().Err(err).Msg("Error closing peer manager")
	}
	logger.Info().Msg("Peer manager closed")

	logger.Info().Msg("Shutdown complete")
}

// setupLogging configures zerolog based on config
func setupLogging(cfg *config.Config) zerolog.Logger {
	// Configure console output with pretty formatting
	output := zerolog.ConsoleWriter{
		Out:        os.Stdout,
		TimeFormat: time.RFC3339,
	}

	// Set log level
	var level zerolog.Level
	switch cfg.LogLevel {
	case "debug":
		level = zerolog.DebugLevel
	case "info":
		level = zerolog.InfoLevel
	case "warn":
		level = zerolog.WarnLevel
	case "error":
		level = zerolog.ErrorLevel
	default:
		level = zerolog.InfoLevel
	}

	zerolog.SetGlobalLevel(level)

	// Create logger with timestamp
	logger := zerolog.New(output).
		With().
		Timestamp().
		Str("service", "webrtc-gateway").
		Logger()

	// Set as global logger
	log.Logger = logger

	return logger
}

// startVideoDistribution connects pipeline output to peer manager
// This runs in a goroutine and writes samples to all connected peers
func startVideoDistribution(ctx context.Context, pipeline *mediapkg.Pipeline, pm *webrtcpkg.PeerManager, logger zerolog.Logger) {
	go func() {
		frameChan := pipeline.VideoFrameChannel()
		if frameChan == nil {
			logger.Warn().Msg("No video frame channel available")
			return
		}

		logger.Debug().Msg("Video distribution started")
		frameDuration := time.Second / 30 // Default to 30fps duration

		for {
			select {
			case <-ctx.Done():
				logger.Debug().Msg("Video distribution stopped")
				return
			case frame, ok := <-frameChan:
				if !ok {
					logger.Debug().Msg("Video frame channel closed")
					return
				}

				// Convert VideoFrame to media.Sample
				sample := media.Sample{
					Data:     frame.Data,
					Duration: frameDuration,
				}

				// Write to all connected peers
				if err := pm.WriteVideoSample(sample); err != nil {
					// Only log if we have connected peers
					if pm.GetConnectedPeerCount() > 0 {
						logger.Debug().Err(err).Msg("Error writing video sample")
					}
				}
			}
		}
	}()
}

// printBanner prints startup banner with ASCII art
func printBanner() {
	banner := `
╔══════════════════════════════════════════════════════════════╗
║           Gaming Capture - WebRTC Gateway                    ║
║                     Phase 4                                  ║
╚══════════════════════════════════════════════════════════════╝
`
	fmt.Print(banner)
}

// printReadyMessage prints the server ready message with connection info
func printReadyMessage(cfg *config.Config) {
	// Determine display address
	addr := cfg.HTTPListenAddr
	if addr[0] == ':' {
		addr = "0.0.0.0" + addr
	}

	var syntheticInfo string
	if cfg.UseSynthetic {
		syntheticInfo = fmt.Sprintf("%dx%d @ %dfps (%s)",
			cfg.SyntheticWidth,
			cfg.SyntheticHeight,
			cfg.SyntheticFPS,
			mediapkg.PatternType(cfg.SyntheticPattern).String())
	} else {
		syntheticInfo = "disabled (IPC mode)"
	}

	readyMsg := fmt.Sprintf(`

═══════════════════════════════════════════════════════════════
  Server ready!
  
  Signaling endpoint: http://%s
  Health check:       http://%s/webrtc/health
  
  Synthetic video:    %s
  
  Press Ctrl+C to stop
═══════════════════════════════════════════════════════════════

`, addr, addr, syntheticInfo)

	fmt.Print(readyMsg)
}
