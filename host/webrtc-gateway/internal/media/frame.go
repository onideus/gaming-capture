package media

// FrameType identifies the type of encoded frame
type FrameType byte

const (
	FrameTypeH264  FrameType = 0x01
	FrameTypeHEVC  FrameType = 0x02
	FrameTypeAudio FrameType = 0x10
)

// FrameFlags contains frame metadata flags
type FrameFlags byte

const (
	FlagKeyframe FrameFlags = 0x01
)

// EncodedFrame represents an encoded video or audio frame
type EncodedFrame struct {
	Type       FrameType
	IsKeyFrame bool
	PTS        int64  // presentation timestamp in microseconds
	Data       []byte // encoded payload (Annex B for video)
}

// HeaderSize is the size of the IPC frame header in bytes
// Type(1) + Flags(1) + PTS(8) + Length(4) = 14
const HeaderSize = 14

func (t FrameType) String() string {
	switch t {
	case FrameTypeH264:
		return "H.264"
	case FrameTypeHEVC:
		return "HEVC"
	case FrameTypeAudio:
		return "Audio"
	default:
		return "Unknown"
	}
}
