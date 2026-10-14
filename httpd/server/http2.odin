package server

// =============================================================================
// http2.odin - just enough HTTP/2 (RFC 9113) to serve unary gRPC.
//
// gRPC REQUIRES HTTP/2 (it needs trailers and multiplexing), so to have one
// gRPC endpoint we need an HTTP/2 server. Without TLS, gRPC clients use "h2c
// with prior knowledge": they open TCP and immediately speak HTTP/2, starting
// with this 24-byte "connection preface":
//
//     PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n
//
// After the preface, everything is a FRAME:
//
//     +-----------------------------------------------+
//     |                 Length (24)                   |   payload length
//     +---------------+---------------+---------------+
//     |   Type (8)    |   Flags (8)   |
//     +-+-------------+---------------+-------------------------------+
//     |R|                 Stream Identifier (31)                      |
//     +=+=============================================================+
//     |                   Frame Payload (0...)                      ...
//     +---------------------------------------------------------------+
//
// A STREAM is one request/response exchange. Many streams share the connection
// (that's the "multiplexing"). Client-started streams have odd ids: 1, 3, 5...
// Stream 0 means "the connection itself" (SETTINGS, PING, GOAWAY...).
//
// A typical unary gRPC call on the wire:
//
//   client -> PREFACE
//   client -> SETTINGS                       (its configuration)
//   server -> SETTINGS                       (ours)
//   server -> SETTINGS + ACK                 ("got yours")
//   client -> SETTINGS + ACK                 ("got yours")
//   client -> HEADERS stream=1 END_HEADERS   (:method POST, :path /pkg.Svc/Method, ...)
//   client -> DATA    stream=1 END_STREAM    (the request message)
//   server -> HEADERS stream=1 END_HEADERS   (:status 200, content-type)
//   server -> DATA    stream=1               (the response message)
//   server -> HEADERS stream=1 END_STREAM    (trailers: grpc-status 0)
//
// What we deliberately skip (fine for small unary calls, NOT for production):
//   - flow control on the SENDING side: we assume our small responses fit in
//     the client's window (65535 bytes by default; grpc-go uses much more),
//   - priorities, server push, stream concurrency limits enforcement.
// We do the RECEIVING side of flow control (WINDOW_UPDATE) so a client can
// send as many requests as it wants on one connection.
// =============================================================================

import "core:log"

H2_PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// Frame types
H2_FRAME_DATA          :: 0x0
H2_FRAME_HEADERS       :: 0x1
H2_FRAME_PRIORITY      :: 0x2
H2_FRAME_RST_STREAM    :: 0x3
H2_FRAME_SETTINGS      :: 0x4
H2_FRAME_PUSH_PROMISE  :: 0x5
H2_FRAME_PING          :: 0x6
H2_FRAME_GOAWAY        :: 0x7
H2_FRAME_WINDOW_UPDATE :: 0x8
H2_FRAME_CONTINUATION  :: 0x9

// Flags (their meaning depends on the frame type)
H2_FLAG_END_STREAM  :: 0x01 // DATA, HEADERS: last frame from this side for the stream
H2_FLAG_ACK         :: 0x01 // SETTINGS, PING: this is an acknowledgement
H2_FLAG_END_HEADERS :: 0x04 // HEADERS, CONTINUATION: header block is complete
H2_FLAG_PADDED      :: 0x08 // DATA, HEADERS: payload has padding
H2_FLAG_PRIORITY    :: 0x20 // HEADERS: 5 bytes of priority info first

// SETTINGS identifiers
H2_SETTINGS_HEADER_TABLE_SIZE      :: 0x1
H2_SETTINGS_ENABLE_PUSH            :: 0x2
H2_SETTINGS_MAX_CONCURRENT_STREAMS :: 0x3
H2_SETTINGS_INITIAL_WINDOW_SIZE    :: 0x4
H2_SETTINGS_MAX_FRAME_SIZE         :: 0x5
H2_SETTINGS_MAX_HEADER_LIST_SIZE   :: 0x6

// Error codes (RST_STREAM, GOAWAY)
H2_NO_ERROR          :: 0x0
H2_PROTOCOL_ERROR    :: 0x1
H2_INTERNAL_ERROR    :: 0x2
H2_FRAME_SIZE_ERROR  :: 0x6
H2_COMPRESSION_ERROR :: 0x9

// The default max frame payload. We never announce a bigger one, so clients
// can't send bigger frames, and we never send bigger ones either.
H2_MAX_FRAME_SIZE :: 16384

H2_Frame :: struct {
	length:    int,
	type:      u8,
	flags:     u8,
	stream_id: u32,
	payload:   []byte, // temp allocator
}

// One request/response exchange.
H2_Stream :: struct {
	id:      u32,
	headers: [dynamic]Header, // decoded request headers (+ trailers), owned
	body:    [dynamic]byte, // concatenated DATA payloads
}

H2_Conn :: struct {
	conn:           ^Conn,
	decoder:        Hpack_Decoder,
	streams:        map[u32]^H2_Stream,
	last_stream_id: u32,

	// A header block may be split: HEADERS (no END_HEADERS) + CONTINUATION...
	// We collect the pieces here; nothing else may arrive in between.
	header_block:            [dynamic]byte,
	header_block_stream_id:  u32, // 0 = not in the middle of a header block
	header_block_end_stream: bool, // the HEADERS frame had END_STREAM
}

// h2_serve runs one HTTP/2 connection until it ends.
h2_serve :: proc(s: ^Server, c: ^Conn) {
	preface, ok := conn_take(c, len(H2_PREFACE), context.temp_allocator)
	if !ok || string(preface) != H2_PREFACE {
		return
	}

	h2 := H2_Conn{conn = c}
	hpack_decoder_init(&h2.decoder, context.allocator)
	h2.streams = make(map[u32]^H2_Stream, context.allocator)
	h2.header_block = make([dynamic]byte, context.allocator)
	defer {
		for _, stream in h2.streams {
			h2_stream_destroy(stream)
		}
		delete(h2.streams)
		delete(h2.header_block)
		hpack_decoder_destroy(&h2.decoder)
	}

	// Our SETTINGS. Each setting is 6 bytes: id (16 bits) + value (32 bits).
	// We only announce MAX_CONCURRENT_STREAMS = 100; everything else default.
	settings := [6]byte{0x00, H2_SETTINGS_MAX_CONCURRENT_STREAMS, 0x00, 0x00, 0x00, 100}
	if !h2_write_frame(&h2, H2_FRAME_SETTINGS, 0, 0, settings[:]) {
		return
	}

	for {
		free_all(context.temp_allocator)

		frame, frame_ok := h2_read_frame(&h2)
		if !frame_ok {
			return
		}

		// While a header block is open, the ONLY allowed frame is a
		// CONTINUATION for that same stream (RFC 9113, 6.10).
		if h2.header_block_stream_id != 0 {
			if frame.type != H2_FRAME_CONTINUATION || frame.stream_id != h2.header_block_stream_id {
				h2_goaway(&h2, H2_PROTOCOL_ERROR)
				return
			}
		}

		keep_going := true
		switch frame.type {
		case H2_FRAME_SETTINGS:
			keep_going = h2_on_settings(&h2, frame)
		case H2_FRAME_PING:
			keep_going = h2_on_ping(&h2, frame)
		case H2_FRAME_HEADERS:
			keep_going = h2_on_headers(s, &h2, frame)
		case H2_FRAME_CONTINUATION:
			keep_going = h2_on_continuation(s, &h2, frame)
		case H2_FRAME_DATA:
			keep_going = h2_on_data(s, &h2, frame)
		case H2_FRAME_RST_STREAM:
			// The client cancelled a stream: forget it.
			if stream, found := h2.streams[frame.stream_id]; found {
				h2_stream_destroy(stream)
				delete_key(&h2.streams, frame.stream_id)
			}
		case H2_FRAME_GOAWAY:
			// The client is closing the connection.
			return
		case H2_FRAME_WINDOW_UPDATE, H2_FRAME_PRIORITY:
		// Ignored: we don't do send-side flow control nor priorities.
		case H2_FRAME_PUSH_PROMISE:
			// Only servers may push.
			h2_goaway(&h2, H2_PROTOCOL_ERROR)
			return
		case:
		// Unknown frame types MUST be ignored (that's how HTTP/2 is extended).
		}
		if !keep_going {
			return
		}
	}
}

// h2_read_frame reads the 9-byte header and then the payload.
h2_read_frame :: proc(h2: ^H2_Conn) -> (frame: H2_Frame, ok: bool) {
	head := conn_take(h2.conn, 9, context.temp_allocator) or_return

	frame.length = int(head[0]) << 16 | int(head[1]) << 8 | int(head[2])
	frame.type = head[3]
	frame.flags = head[4]
	// The top bit is reserved and must be ignored -> mask with 0x7fffffff.
	frame.stream_id = (u32(head[5]) << 24 | u32(head[6]) << 16 | u32(head[7]) << 8 | u32(head[8])) & 0x7FFF_FFFF

	if frame.length > H2_MAX_FRAME_SIZE {
		h2_goaway(h2, H2_FRAME_SIZE_ERROR)
		return {}, false
	}
	frame.payload = conn_take(h2.conn, frame.length, context.temp_allocator) or_return
	return frame, true
}

// h2_write_frame builds the 9-byte header + payload and sends it.
h2_write_frame :: proc(h2: ^H2_Conn, type: u8, flags: u8, stream_id: u32, payload: []byte) -> bool {
	frame := make([]byte, 9 + len(payload), context.temp_allocator)
	length := len(payload)
	frame[0] = u8(length >> 16)
	frame[1] = u8(length >> 8)
	frame[2] = u8(length)
	frame[3] = type
	frame[4] = flags
	frame[5] = u8(stream_id >> 24)
	frame[6] = u8(stream_id >> 16)
	frame[7] = u8(stream_id >> 8)
	frame[8] = u8(stream_id)
	copy(frame[9:], payload)
	return conn_send(h2.conn, frame)
}

// h2_goaway: "I'm closing this connection, and this is why."
h2_goaway :: proc(h2: ^H2_Conn, error_code: u32) {
	payload: [8]byte
	// Last stream id we processed (31 bits), then the error code.
	payload[0] = u8(h2.last_stream_id >> 24)
	payload[1] = u8(h2.last_stream_id >> 16)
	payload[2] = u8(h2.last_stream_id >> 8)
	payload[3] = u8(h2.last_stream_id)
	payload[4] = u8(error_code >> 24)
	payload[5] = u8(error_code >> 16)
	payload[6] = u8(error_code >> 8)
	payload[7] = u8(error_code)
	h2_write_frame(h2, H2_FRAME_GOAWAY, 0, 0, payload[:])
	log.debugf("http2: sent GOAWAY error=%d", error_code)
}

h2_window_update :: proc(h2: ^H2_Conn, stream_id: u32, increment: u32) -> bool {
	payload := [4]byte{u8(increment >> 24), u8(increment >> 16), u8(increment >> 8), u8(increment)}
	return h2_write_frame(h2, H2_FRAME_WINDOW_UPDATE, 0, stream_id, payload[:])
}

h2_stream_destroy :: proc(stream: ^H2_Stream) {
	for h in stream.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(stream.headers)
	delete(stream.body)
	free(stream)
}

// h2_stream_header finds a request header (HTTP/2 header names are always
// lowercase, so a plain comparison is enough).
h2_stream_header :: proc(stream: ^H2_Stream, name: string) -> string {
	for h in stream.headers {
		if h.name == name {
			return h.value
		}
	}
	return ""
}

// -----------------------------------------------------------------------------
// Frame handlers. They return false when the connection must be closed.
// -----------------------------------------------------------------------------

h2_on_settings :: proc(h2: ^H2_Conn, frame: H2_Frame) -> bool {
	if frame.stream_id != 0 || frame.length % 6 != 0 {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	if frame.flags & H2_FLAG_ACK != 0 {
		return true // the client acknowledged OUR settings
	}
	// Just log the client's settings; we don't need to act on any of them
	// for small unary responses.
	for i := 0; i < frame.length; i += 6 {
		p := frame.payload[i:]
		id := u16(p[0]) << 8 | u16(p[1])
		value := u32(p[2]) << 24 | u32(p[3]) << 16 | u32(p[4]) << 8 | u32(p[5])
		log.debugf("http2: client setting %d = %d", id, value)
	}
	// Every SETTINGS must be acknowledged with an empty SETTINGS + ACK.
	return h2_write_frame(h2, H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, nil)
}

h2_on_ping :: proc(h2: ^H2_Conn, frame: H2_Frame) -> bool {
	if frame.stream_id != 0 || frame.length != 8 {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	if frame.flags & H2_FLAG_ACK != 0 {
		return true
	}
	// Answer with the same 8 opaque bytes + ACK.
	return h2_write_frame(h2, H2_FRAME_PING, H2_FLAG_ACK, 0, frame.payload)
}

// h2_strip_padding removes the PADDED framing:
// [pad length (1 byte)] [data...] [padding (pad length bytes)]
@(private)
h2_strip_padding :: proc(payload: []byte, flags: u8) -> (data: []byte, ok: bool) {
	data = payload
	if flags & H2_FLAG_PADDED != 0 {
		if len(data) < 1 {
			return nil, false
		}
		pad_length := int(data[0])
		data = data[1:]
		if pad_length > len(data) {
			return nil, false
		}
		data = data[:len(data) - pad_length]
	}
	return data, true
}

h2_on_headers :: proc(s: ^Server, h2: ^H2_Conn, frame: H2_Frame) -> bool {
	if frame.stream_id == 0 {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	fragment, ok := h2_strip_padding(frame.payload, frame.flags)
	if !ok {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	if frame.flags & H2_FLAG_PRIORITY != 0 {
		// 4 bytes stream dependency + 1 byte weight. We don't do priorities.
		if len(fragment) < 5 {
			h2_goaway(h2, H2_PROTOCOL_ERROR)
			return false
		}
		fragment = fragment[5:]
	}

	if _, exists := h2.streams[frame.stream_id]; !exists {
		// A new stream. Client stream ids must be odd and always increasing.
		if frame.stream_id % 2 == 0 || frame.stream_id <= h2.last_stream_id {
			h2_goaway(h2, H2_PROTOCOL_ERROR)
			return false
		}
		h2.last_stream_id = frame.stream_id
		stream := new(H2_Stream)
		stream.id = frame.stream_id
		h2.streams[frame.stream_id] = stream
	}
	// (If the stream already exists, these are trailers sent by the client.
	// We decode them like any header block; unary gRPC clients don't send them.)

	append(&h2.header_block, ..fragment)
	h2.header_block_end_stream = frame.flags & H2_FLAG_END_STREAM != 0

	if frame.flags & H2_FLAG_END_HEADERS != 0 {
		return h2_finish_header_block(s, h2, frame.stream_id)
	}
	h2.header_block_stream_id = frame.stream_id // expect CONTINUATION frames
	return true
}

h2_on_continuation :: proc(s: ^Server, h2: ^H2_Conn, frame: H2_Frame) -> bool {
	if h2.header_block_stream_id == 0 {
		// CONTINUATION without a HEADERS before it.
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	append(&h2.header_block, ..frame.payload)
	if len(h2.header_block) > MAX_HEADER_BYTES {
		// Endless CONTINUATION frames would make us buffer forever.
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	if frame.flags & H2_FLAG_END_HEADERS != 0 {
		return h2_finish_header_block(s, h2, frame.stream_id)
	}
	return true
}

// h2_finish_header_block HPACK-decodes the collected header block.
h2_finish_header_block :: proc(s: ^Server, h2: ^H2_Conn, stream_id: u32) -> bool {
	stream := h2.streams[stream_id]
	decoded := hpack_decode_block(&h2.decoder, h2.header_block[:], &stream.headers, context.allocator)
	clear(&h2.header_block)
	h2.header_block_stream_id = 0
	if !decoded {
		// The HPACK state is now unknown; the whole connection is unusable.
		h2_goaway(h2, H2_COMPRESSION_ERROR)
		return false
	}
	if h2.header_block_end_stream {
		// Request without body (e.g. a GET). The client is done: respond.
		return h2_dispatch(s, h2, stream)
	}
	return true
}

h2_on_data :: proc(s: ^Server, h2: ^H2_Conn, frame: H2_Frame) -> bool {
	if frame.stream_id == 0 {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}

	// Flow control, receiving side: every DATA payload (padding included)
	// consumes the client's send window for the connection. Give it back right
	// away, otherwise after 64 KiB in total the client would stop sending.
	if frame.length > 0 {
		if !h2_window_update(h2, 0, u32(frame.length)) {
			return false
		}
	}

	stream, exists := h2.streams[frame.stream_id]
	if !exists {
		// DATA for a stream we already finished or reset. Ignore it.
		return true
	}
	data, ok := h2_strip_padding(frame.payload, frame.flags)
	if !ok {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}
	append(&stream.body, ..data)
	if len(stream.body) > MAX_BODY_BYTES {
		h2_goaway(h2, H2_PROTOCOL_ERROR)
		return false
	}

	if frame.flags & H2_FLAG_END_STREAM != 0 {
		return h2_dispatch(s, h2, stream)
	}
	// More DATA will come on this stream: refill its own window too.
	if frame.length > 0 {
		return h2_window_update(h2, frame.stream_id, u32(frame.length))
	}
	return true
}

// h2_dispatch: the client finished sending its request; produce the response
// and forget the stream.
h2_dispatch :: proc(s: ^Server, h2: ^H2_Conn, stream: ^H2_Stream) -> bool {
	ok := grpc_handle_stream(s, h2, stream)
	delete_key(&h2.streams, stream.id)
	h2_stream_destroy(stream)
	return ok
}

// -----------------------------------------------------------------------------
// Response writers
// -----------------------------------------------------------------------------

// h2_write_headers HPACK-encodes `headers` and sends them as ONE HEADERS frame
// (our header blocks are tiny, way below H2_MAX_FRAME_SIZE).
h2_write_headers :: proc(h2: ^H2_Conn, stream_id: u32, headers: []Header, end_stream: bool) -> bool {
	block := make([dynamic]byte, 0, 128, context.temp_allocator)
	for h in headers {
		if h.name == ":status" && h.value == "200" {
			hpack_append_indexed(&block, 8) // static table entry 8 = ":status: 200"
		} else {
			hpack_append_literal(&block, h.name, h.value)
		}
	}
	flags := u8(H2_FLAG_END_HEADERS)
	if end_stream {
		flags |= H2_FLAG_END_STREAM
	}
	return h2_write_frame(h2, H2_FRAME_HEADERS, flags, stream_id, block[:])
}

// h2_write_data sends `data`, split in frames of at most H2_MAX_FRAME_SIZE.
h2_write_data :: proc(h2: ^H2_Conn, stream_id: u32, data: []byte, end_stream: bool) -> bool {
	rest := data
	for {
		chunk := rest[:min(len(rest), H2_MAX_FRAME_SIZE)]
		rest = rest[len(chunk):]
		is_last := len(rest) == 0
		flags := u8(0)
		if is_last && end_stream {
			flags = H2_FLAG_END_STREAM
		}
		if !h2_write_frame(h2, H2_FRAME_DATA, flags, stream_id, chunk) {
			return false
		}
		if is_last {
			return true
		}
	}
}
