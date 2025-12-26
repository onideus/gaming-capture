package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/config"
	"github.com/zachmartin/gaming-capture/host/webrtc-gateway/internal/media"
)

func main() {
	cfg := config.Load()

	log.Printf("WebRTC Gateway starting...")
	log.Printf("  IPC Socket: %s", cfg.IPCSocketPath)
	log.Printf("  HTTP Addr:  %s", cfg.HTTPListenAddr)
	log.Printf("  Codec:      %s", cfg.VideoCodec)
	log.Printf("  Max Bitrate: %d kbps", cfg.MaxBitrateKbps)

	// Start IPC consumer
	ipc := media.NewIPCConsumer(cfg.IPCSocketPath)
	if err := ipc.Start(); err != nil {
		log.Fatalf("Failed to start IPC consumer: %v", err)
	}

	// Frame consumer goroutine (placeholder - will feed into WebRTC in Phase 4)
	go func() {
		for frame := range ipc.Frames {
			// For now, just log keyframes
			if frame.IsKeyFrame {
				log.Printf("Received keyframe: %s, %d bytes, PTS=%d",
					frame.Type, len(frame.Data), frame.PTS)
			}
		}
	}()

	// Setup HTTP server with placeholder routes
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("/webrtc/offer", func(w http.ResponseWriter, r *http.Request) {
		// TODO: Implement signaling
		http.Error(w, "not implemented", http.StatusNotImplemented)
	})
	mux.HandleFunc("/webrtc/candidate", func(w http.ResponseWriter, r *http.Request) {
		// TODO: Implement ICE candidate handling
		http.Error(w, "not implemented", http.StatusNotImplemented)
	})

	server := &http.Server{
		Addr:    cfg.HTTPListenAddr,
		Handler: mux,
	}

	// Graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		log.Println("Shutting down...")
		cancel()
		ipc.Stop()
		server.Shutdown(context.Background())
	}()

	log.Printf("HTTP server listening on %s", cfg.HTTPListenAddr)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("HTTP server error: %v", err)
	}

	<-ctx.Done()
	log.Println("Gateway stopped")
}
