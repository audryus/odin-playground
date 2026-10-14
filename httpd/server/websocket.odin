package server

// =============================================================================
// websocket.odin - WebSocket by hand (RFC 6455).
//
// A WebSocket starts life as a normal HTTP/1.1 request:
//
//     GET /ws HTTP/1.1
//     Upgrade: websocket
//     Connection: Upgrade
//     Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==     <- random 16 bytes, base64
//     Sec-WebSocket-Version: 13
//
// The server agrees with:
//
//     HTTP/1.1 101 Switching Protocols
//     Upgrade: websocket
//     Connection: Upgrade
//     Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
//
// where Accept = base64( sha1( Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) ).
// (That GUID is a fixed constant from the RFC. The point is only to prove the
// server really understands WebSocket, it's not security.)
//
// After the 101, the same TCP connection carries FRAMES in both directions:
//
//      0                   1                   2                   3
//      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//     +-+-+-+-+-------+-+-------------+-------------------------------+
//     |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
//     |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
//     |N|V|V|V|       |S|             |   (if payload len==126/127)   |
//     | |1|2|3|       |K|             |                               |
//     +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
//     |     Extended payload length continued, if payload len == 127  |
//     + - - - - - - - - - - - - - - - +-------------------------------+
//     |                               |Masking-key, if MASK set to 1  |
//     +-------------------------------+-------------------------------+
//     | Masking-key (continued)       |          Payload Data         |
//     +-------------------------------- - - - - - - - - - - - - - - - +
//
//   FIN     : 1 = last frame of a message (messages can be fragmented)
//   opcode  : 0 continuation, 1 text, 2 binary, 8 close, 9 ping, 10 pong
//   MASK    : client->server frames MUST be masked, server->client MUST NOT
//   length  : 0..125 inline; 126 = next 2 bytes; 127 = next 8 bytes
//
// What this server does with a connection:
//   - echoes every text/binary message back,
//   - answers ping with pong,
//   - answers close with close,
//   - pushes {"event":"note_created",...} etc. whenever the REST API changes a
//     note (see websocket_broadcast_note_event).
// =============================================================================

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/json"
import "core:net"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

WEBSOCKET_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

WS_OPCODE_CONTINUATION :: 0x0
WS_OPCODE_TEXT         :: 0x1
WS_OPCODE_BINARY       :: 0x2
WS_OPCODE_CLOSE        :: 0x8
WS_OPCODE_PING         :: 0x9
WS_OPCODE_PONG         :: 0xA

// Close status codes (RFC 6455, 7.4.1)
WS_CLOSE_NORMAL         :: 1000
WS_CLOSE_PROTOCOL_ERROR :: 1002
WS_CLOSE_INVALID_DATA   :: 1007 // e.g. a text message that isn't UTF-8
WS_CLOSE_TOO_BIG        :: 1009

WS_MAX_MESSAGE_BYTES :: 1024 * 1024

// One connected WebSocket client.
//
// Two different threads may write to the same socket: the client's own
// connection thread (echo, pong) and any REST thread broadcasting an event.
// Two frames written at the same time could interleave their bytes, so every
// write takes send_mutex.
Ws_Client :: struct {
	socket:     net.TCP_Socket,
	send_mutex: sync.Mutex,
}

Ws_Frame :: struct {
	fin:     bool,
	opcode:  u8,
	payload: []byte, // already unmasked; allocated with context.allocator
}

Ws_Read_Result :: enum {
	Ok,
	Closed,         // connection dropped
	Protocol_Error, // the client broke the rules -> close 1002
	Too_Big,        // -> close 1009
}

// Note_Event is what gets broadcast to WebSocket clients.
Note_Event :: struct {
	event: string `json:"event"`,
	note:  Note `json:"note"`,
}

// websocket_is_upgrade_request: is this HTTP request asking for a WebSocket?
websocket_is_upgrade_request :: proc(req: ^Request) -> bool {
	upgrade, _ := header_get(req.headers[:], "Upgrade")
	return req.method == "GET" && req.path == "/ws" && strings.equal_fold(upgrade, "websocket")
}

// websocket_accept_key computes Sec-WebSocket-Accept from Sec-WebSocket-Key.
websocket_accept_key :: proc(key: string, allocator := context.allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)key)
	sha1.update(&ctx, transmute([]byte)string(WEBSOCKET_GUID))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

// websocket_serve does the handshake and then runs the frame loop until the
// connection is closed.
websocket_serve :: proc(s: ^Server, c: ^Conn, req: ^Request) {
	// --- 1. Validate the handshake request -------------------------------------
	key, has_key := header_get(req.headers[:], "Sec-WebSocket-Key")
	version, _ := header_get(req.headers[:], "Sec-WebSocket-Version")
	connection, _ := header_get(req.headers[:], "Connection")
	// "Connection" may be a list, e.g. "keep-alive, Upgrade" (Firefox does that).
	connection_has_upgrade := strings.contains(strings.to_lower(connection, context.temp_allocator), "upgrade")

	if !has_key || !connection_has_upgrade {
		http1_write_error(c, 400)
		return
	}
	if version != "13" {
		// Tell the client which version we speak.
		conn_send(c, transmute([]byte)string(
			"HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		))
		return
	}

	// --- 2. Register the client BEFORE answering 101 ---------------------------
	// So that as soon as the client sees the 101, it's guaranteed to receive
	// broadcasts. (Tests rely on this ordering.)
	client := new(Ws_Client, s.allocator)
	client.socket = c.socket
	sync.mutex_lock(&s.ws_mutex)
	append(&s.ws_clients, client)
	sync.mutex_unlock(&s.ws_mutex)

	// --- 3. Answer 101 Switching Protocols --------------------------------------
	accept := websocket_accept_key(key, context.temp_allocator)
	handshake := strings.concatenate({
		"HTTP/1.1 101 Switching Protocols\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Accept: ", accept, "\r\n",
		"\r\n",
	}, context.temp_allocator)

	sync.mutex_lock(&client.send_mutex)
	handshake_ok := conn_send(c, transmute([]byte)handshake)
	sync.mutex_unlock(&client.send_mutex)

	// From here on, `req` is dead: its memory is in the temp allocator.
	free_all(context.temp_allocator)

	if handshake_ok {
		websocket_frame_loop(s, c, client)
	}

	// --- 4. Unregister and free ---------------------------------------------------
	sync.mutex_lock(&s.ws_mutex)
	for other, i in s.ws_clients {
		if other == client {
			unordered_remove(&s.ws_clients, i)
			break
		}
	}
	sync.mutex_unlock(&s.ws_mutex)
	free(client, s.allocator)
}

// websocket_frame_loop reads frames until the connection ends.
@(private)
websocket_frame_loop :: proc(s: ^Server, c: ^Conn, client: ^Ws_Client) {
	// A message may be split into several frames:
	//   [TEXT fin=0] [CONTINUATION fin=0] [CONTINUATION fin=1]
	// We accumulate the pieces here until FIN.
	message: [dynamic]byte
	message_opcode: u8 = 0 // 0 = not in the middle of a fragmented message
	defer delete(message)

	for {
		free_all(context.temp_allocator)

		frame, result := websocket_read_frame(c)
		defer delete(frame.payload)

		switch result {
		case .Ok:
		case .Closed:
			return
		case .Protocol_Error:
			websocket_send_close(client, WS_CLOSE_PROTOCOL_ERROR)
			return
		case .Too_Big:
			websocket_send_close(client, WS_CLOSE_TOO_BIG)
			return
		}

		switch frame.opcode {
		// --- Control frames: can arrive even in the middle of a fragmented message.
		case WS_OPCODE_PING:
			// A pong must carry the same payload as the ping.
			websocket_write_frame(client, WS_OPCODE_PONG, frame.payload)

		case WS_OPCODE_PONG:
		// We never send pings, so we can ignore pongs.

		case WS_OPCODE_CLOSE:
			// Echo the status code back (first 2 bytes of the payload) and stop.
			// After sending a close frame, we must not send anything else.
			code := u16(WS_CLOSE_NORMAL)
			if len(frame.payload) >= 2 {
				code = u16(frame.payload[0]) << 8 | u16(frame.payload[1])
			}
			websocket_send_close(client, code)
			return

		// --- Data frames
		case WS_OPCODE_TEXT, WS_OPCODE_BINARY:
			if message_opcode != 0 {
				// A new message started before the previous one finished.
				websocket_send_close(client, WS_CLOSE_PROTOCOL_ERROR)
				return
			}
			message_opcode = frame.opcode
			append(&message, ..frame.payload)

		case WS_OPCODE_CONTINUATION:
			if message_opcode == 0 {
				// Continuation of... nothing.
				websocket_send_close(client, WS_CLOSE_PROTOCOL_ERROR)
				return
			}
			append(&message, ..frame.payload)

		case:
			// Opcodes 3-7 and 11-15 are reserved.
			websocket_send_close(client, WS_CLOSE_PROTOCOL_ERROR)
			return
		}

		if len(message) > WS_MAX_MESSAGE_BYTES {
			websocket_send_close(client, WS_CLOSE_TOO_BIG)
			return
		}

		// A data message is complete when its last frame has FIN set.
		is_data_frame := frame.opcode == WS_OPCODE_TEXT || frame.opcode == WS_OPCODE_BINARY || frame.opcode == WS_OPCODE_CONTINUATION
		if is_data_frame && frame.fin {
			if message_opcode == WS_OPCODE_TEXT && !utf8.valid_string(string(message[:])) {
				websocket_send_close(client, WS_CLOSE_INVALID_DATA)
				return
			}
			// This is the "application": an echo.
			if !websocket_write_frame(client, message_opcode, message[:]) {
				return
			}
			clear(&message)
			message_opcode = 0
		}
	}
}

// websocket_read_frame reads ONE frame (see the diagram at the top).
websocket_read_frame :: proc(c: ^Conn) -> (frame: Ws_Frame, result: Ws_Read_Result) {
	// --- Byte 0 and 1 -------------------------------------------------------------
	head, ok := conn_take(c, 2, context.temp_allocator)
	if !ok {
		return {}, .Closed
	}
	frame.fin = head[0] & 0x80 != 0
	rsv := head[0] & 0x70 // RSV1..3: only used by extensions; we negotiated none
	frame.opcode = head[0] & 0x0F
	masked := head[1] & 0x80 != 0
	length := u64(head[1] & 0x7F)

	if rsv != 0 {
		return {}, .Protocol_Error
	}

	// --- Extended length (big-endian) -------------------------------------------
	if length == 126 {
		ext, ext_ok := conn_take(c, 2, context.temp_allocator)
		if !ext_ok {
			return {}, .Closed
		}
		length = u64(ext[0]) << 8 | u64(ext[1])
	} else if length == 127 {
		ext, ext_ok := conn_take(c, 8, context.temp_allocator)
		if !ext_ok {
			return {}, .Closed
		}
		length = 0
		for b in ext {
			length = length << 8 | u64(b)
		}
	}

	// Control frames (opcode >= 8) can't be fragmented and are at most 125 bytes.
	if frame.opcode >= 0x8 && (!frame.fin || length > 125) {
		return {}, .Protocol_Error
	}
	// Clients MUST mask every frame (RFC 6455, 5.1).
	if !masked {
		return {}, .Protocol_Error
	}
	if length > WS_MAX_MESSAGE_BYTES {
		return {}, .Too_Big
	}

	// --- Masking key + payload -------------------------------------------------------
	mask_key, mask_ok := conn_take(c, 4, context.temp_allocator)
	if !mask_ok {
		return {}, .Closed
	}
	payload, payload_ok := conn_take(c, int(length), context.allocator)
	if !payload_ok {
		delete(payload)
		return {}, .Closed
	}
	// Unmask: XOR every byte with the key, cycling through its 4 bytes.
	for i in 0 ..< len(payload) {
		payload[i] ~= mask_key[i % 4]
	}
	frame.payload = payload
	return frame, .Ok
}

// websocket_write_frame sends one unmasked, unfragmented (FIN=1) frame.
websocket_write_frame :: proc(client: ^Ws_Client, opcode: u8, payload: []byte) -> bool {
	header: [10]byte
	header_length: int
	header[0] = 0x80 | opcode // FIN + opcode

	length := len(payload)
	if length < 126 {
		header[1] = u8(length)
		header_length = 2
	} else if length <= 0xFFFF {
		header[1] = 126
		header[2] = u8(length >> 8)
		header[3] = u8(length)
		header_length = 4
	} else {
		header[1] = 127
		for i in 0 ..< 8 {
			header[2 + i] = u8(u64(length) >> uint(56 - 8 * i))
		}
		header_length = 10
	}

	sync.mutex_lock(&client.send_mutex)
	defer sync.mutex_unlock(&client.send_mutex)

	if _, err := net.send_tcp(client.socket, header[:header_length]); err != nil {
		return false
	}
	if length > 0 {
		if _, err := net.send_tcp(client.socket, payload); err != nil {
			return false
		}
	}
	return true
}

websocket_send_close :: proc(client: ^Ws_Client, code: u16) {
	payload := [2]byte{u8(code >> 8), u8(code)}
	websocket_write_frame(client, WS_OPCODE_CLOSE, payload[:])
}

// websocket_broadcast_note_event sends a JSON text message to every client.
// Called from REST handlers, i.e. from OTHER connection threads.
websocket_broadcast_note_event :: proc(s: ^Server, event: string, note: Note) {
	data, err := json.marshal(Note_Event{event = event, note = note}, allocator = context.temp_allocator)
	if err != nil {
		return
	}

	sync.mutex_lock(&s.ws_mutex)
	defer sync.mutex_unlock(&s.ws_mutex)
	for client in s.ws_clients {
		// If a client is gone the write fails; its own thread will clean it up.
		websocket_write_frame(client, WS_OPCODE_TEXT, data)
	}
}
