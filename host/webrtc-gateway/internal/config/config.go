// Package config provides configuration management for the WebRTC Gateway.
// Configuration can be loaded from environment variables or initialized with defaults.
package config

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

// Config holds all configuration for the WebRTC Gateway.
type Config struct {
	// IPCSocketPath is the Unix socket path for receiving encoded frames.
	// Default: "/tmp/elgato_stream.sock"
	IPCSocketPath string

	// HTTPListenAddr is the address for the HTTP signaling server.
	// Default: ":8080"
	HTTPListenAddr string

	// AllowedOrigins specifies CORS allowed origins.
	// Default: ["*"]
	AllowedOrigins []string

	// VideoCodec specifies the video codec ("h264" or "hevc").
	// Default: "h264"
	VideoCodec string

	// MaxBitrateKbps is the maximum video bitrate in kbps.
	// Default: 5000
	MaxBitrateKbps int

	// LogLevel specifies logging verbosity ("debug", "info", "warn", "error").
	// Default: "info"
	LogLevel string

	// UseSynthetic enables synthetic video generation instead of IPC input.
	// Default: false
	UseSynthetic bool

	// SyntheticWidth is the width of synthetic video frames.
	// Default: 1280
	SyntheticWidth int

	// SyntheticHeight is the height of synthetic video frames.
	// Default: 720
	SyntheticHeight int

	// SyntheticFPS is the frame rate for synthetic video.
	// Default: 30
	SyntheticFPS int

	// SyntheticPattern is the test pattern type (0=ColorBars, 1=Gradient, 2=Grid).
	// Default: 0 (ColorBars)
	SyntheticPattern int
}

// Default returns a Config with default values.
func Default() *Config {
	return &Config{
		IPCSocketPath:    "/tmp/elgato_stream.sock",
		HTTPListenAddr:   ":8080",
		AllowedOrigins:   []string{"*"},
		VideoCodec:       "h264",
		MaxBitrateKbps:   5000,
		LogLevel:         "info",
		UseSynthetic:     false,
		SyntheticWidth:   1280,
		SyntheticHeight:  720,
		SyntheticFPS:     30,
		SyntheticPattern: 0,
	}
}

// Load loads configuration from environment variables, falling back to defaults
// for any values not specified.
//
// Environment variables:
//   - GATEWAY_IPC_SOCKET_PATH: Unix socket path
//   - GATEWAY_HTTP_LISTEN_ADDR: HTTP server listen address
//   - GATEWAY_ALLOWED_ORIGINS: Comma-separated list of allowed CORS origins
//   - GATEWAY_VIDEO_CODEC: Video codec (h264 or hevc)
//   - GATEWAY_MAX_BITRATE_KBPS: Maximum video bitrate in kbps
//   - GATEWAY_LOG_LEVEL: Logging level (debug, info, warn, error)
//   - GATEWAY_USE_SYNTHETIC: Enable synthetic video (true/false)
//   - GATEWAY_SYNTHETIC_WIDTH: Synthetic video width
//   - GATEWAY_SYNTHETIC_HEIGHT: Synthetic video height
//   - GATEWAY_SYNTHETIC_FPS: Synthetic video frame rate
//   - GATEWAY_SYNTHETIC_PATTERN: Synthetic video pattern (0=ColorBars, 1=Gradient, 2=Grid)
func Load() (*Config, error) {
	cfg := Default()

	if val := os.Getenv("GATEWAY_IPC_SOCKET_PATH"); val != "" {
		cfg.IPCSocketPath = val
	}

	if val := os.Getenv("GATEWAY_HTTP_LISTEN_ADDR"); val != "" {
		cfg.HTTPListenAddr = val
	}

	if val := os.Getenv("GATEWAY_ALLOWED_ORIGINS"); val != "" {
		origins := strings.Split(val, ",")
		cfg.AllowedOrigins = make([]string, 0, len(origins))
		for _, origin := range origins {
			trimmed := strings.TrimSpace(origin)
			if trimmed != "" {
				cfg.AllowedOrigins = append(cfg.AllowedOrigins, trimmed)
			}
		}
	}

	if val := os.Getenv("GATEWAY_VIDEO_CODEC"); val != "" {
		cfg.VideoCodec = strings.ToLower(strings.TrimSpace(val))
	}

	if val := os.Getenv("GATEWAY_MAX_BITRATE_KBPS"); val != "" {
		bitrate, err := strconv.Atoi(val)
		if err != nil {
			return nil, errors.New("GATEWAY_MAX_BITRATE_KBPS must be a valid integer")
		}
		cfg.MaxBitrateKbps = bitrate
	}

	if val := os.Getenv("GATEWAY_LOG_LEVEL"); val != "" {
		cfg.LogLevel = strings.ToLower(strings.TrimSpace(val))
	}

	if val := os.Getenv("GATEWAY_USE_SYNTHETIC"); val != "" {
		cfg.UseSynthetic = strings.ToLower(strings.TrimSpace(val)) == "true"
	}

	if val := os.Getenv("GATEWAY_SYNTHETIC_WIDTH"); val != "" {
		width, err := strconv.Atoi(val)
		if err != nil {
			return nil, errors.New("GATEWAY_SYNTHETIC_WIDTH must be a valid integer")
		}
		cfg.SyntheticWidth = width
	}

	if val := os.Getenv("GATEWAY_SYNTHETIC_HEIGHT"); val != "" {
		height, err := strconv.Atoi(val)
		if err != nil {
			return nil, errors.New("GATEWAY_SYNTHETIC_HEIGHT must be a valid integer")
		}
		cfg.SyntheticHeight = height
	}

	if val := os.Getenv("GATEWAY_SYNTHETIC_FPS"); val != "" {
		fps, err := strconv.Atoi(val)
		if err != nil {
			return nil, errors.New("GATEWAY_SYNTHETIC_FPS must be a valid integer")
		}
		cfg.SyntheticFPS = fps
	}

	if val := os.Getenv("GATEWAY_SYNTHETIC_PATTERN"); val != "" {
		pattern, err := strconv.Atoi(val)
		if err != nil {
			return nil, errors.New("GATEWAY_SYNTHETIC_PATTERN must be a valid integer")
		}
		cfg.SyntheticPattern = pattern
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// Validate checks that the configuration values are valid.
func (c *Config) Validate() error {
	if c.IPCSocketPath == "" {
		return errors.New("IPCSocketPath cannot be empty")
	}

	if c.HTTPListenAddr == "" {
		return errors.New("HTTPListenAddr cannot be empty")
	}

	if len(c.AllowedOrigins) == 0 {
		return errors.New("AllowedOrigins cannot be empty")
	}

	validCodecs := map[string]bool{"h264": true, "hevc": true}
	if !validCodecs[c.VideoCodec] {
		return errors.New("VideoCodec must be 'h264' or 'hevc'")
	}

	if c.MaxBitrateKbps <= 0 {
		return errors.New("MaxBitrateKbps must be a positive integer")
	}

	if c.MaxBitrateKbps > 100000 {
		return errors.New("MaxBitrateKbps exceeds maximum allowed value of 100000")
	}

	validLogLevels := map[string]bool{
		"debug": true,
		"info":  true,
		"warn":  true,
		"error": true,
	}
	if !validLogLevels[c.LogLevel] {
		return errors.New("LogLevel must be 'debug', 'info', 'warn', or 'error'")
	}

	// Validate synthetic config if enabled
	if c.UseSynthetic {
		if c.SyntheticWidth <= 0 || c.SyntheticWidth > 7680 {
			return errors.New("SyntheticWidth must be between 1 and 7680")
		}
		if c.SyntheticHeight <= 0 || c.SyntheticHeight > 4320 {
			return errors.New("SyntheticHeight must be between 1 and 4320")
		}
		if c.SyntheticFPS <= 0 || c.SyntheticFPS > 240 {
			return errors.New("SyntheticFPS must be between 1 and 240")
		}
		if c.SyntheticPattern < 0 || c.SyntheticPattern > 2 {
			return errors.New("SyntheticPattern must be 0 (ColorBars), 1 (Gradient), or 2 (Grid)")
		}
	}

	return nil
}

// IsDebug returns true if the log level is set to debug.
func (c *Config) IsDebug() bool {
	return c.LogLevel == "debug"
}

// IsSynthetic returns true if synthetic video is enabled.
func (c *Config) IsSynthetic() bool {
	return c.UseSynthetic
}

// String returns a string representation of the config for logging purposes.
// Sensitive values should be masked if any are added in the future.
func (c *Config) String() string {
	syntheticInfo := ""
	if c.UseSynthetic {
		syntheticInfo = ", UseSynthetic: true, " +
			"SyntheticWidth: " + strconv.Itoa(c.SyntheticWidth) + ", " +
			"SyntheticHeight: " + strconv.Itoa(c.SyntheticHeight) + ", " +
			"SyntheticFPS: " + strconv.Itoa(c.SyntheticFPS) + ", " +
			"SyntheticPattern: " + strconv.Itoa(c.SyntheticPattern)
	}

	return "Config{" +
		"IPCSocketPath: " + c.IPCSocketPath + ", " +
		"HTTPListenAddr: " + c.HTTPListenAddr + ", " +
		"AllowedOrigins: [" + strings.Join(c.AllowedOrigins, ", ") + "], " +
		"VideoCodec: " + c.VideoCodec + ", " +
		"MaxBitrateKbps: " + strconv.Itoa(c.MaxBitrateKbps) + ", " +
		"LogLevel: " + c.LogLevel +
		syntheticInfo +
		"}"
}
