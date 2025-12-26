package config

import (
	"flag"
	"os"
)

// Config holds the WebRTC gateway configuration.
type Config struct {
	IPCSocketPath  string
	HTTPListenAddr string
	VideoCodec     string // "h264" or "hevc"
	MaxBitrateKbps int
}

// Load parses configuration from command-line flags and environment variables.
func Load() *Config {
	cfg := &Config{}

	flag.StringVar(&cfg.IPCSocketPath, "ipc-socket", "/tmp/elgato_stream.sock", "Unix socket path for IPC with capture service")
	flag.StringVar(&cfg.HTTPListenAddr, "http-addr", ":8080", "HTTP listen address for signaling")
	flag.StringVar(&cfg.VideoCodec, "codec", "h264", "Video codec (h264 or hevc)")
	flag.IntVar(&cfg.MaxBitrateKbps, "max-bitrate", 25000, "Maximum video bitrate in kbps")

	flag.Parse()

	// Environment variable overrides
	if v := os.Getenv("IPC_SOCKET_PATH"); v != "" {
		cfg.IPCSocketPath = v
	}
	if v := os.Getenv("HTTP_LISTEN_ADDR"); v != "" {
		cfg.HTTPListenAddr = v
	}

	return cfg
}
