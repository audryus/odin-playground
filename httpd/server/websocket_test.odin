package server

// =============================================================================
// websocket_test.odin - handshake, frames, echo, broadcast, protocol errors.
// =============================================================================

import "core:testing"

// The worked example from RFC 6455, section 1.3.
@(test)
test_websocket_accept_key :: proc(t: ^testing.T) {
	accept := websocket_accept_key(TEST_WS_KEY, context.temp_allocator)
	testing.expect_value(t, accept, TEST_WS_ACCEPT)
}

@(test)
test_websocket_echo_text :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	test_ws_send_frame(&c, WS_OPCODE_TEXT, transmute([]byte)string("hello odin"))
	opcode, payload, read_ok := test_ws_read_frame(&c)
	testing.expect(t, read_ok)
	testing.expect_value(t, opcode, WS_OPCODE_TEXT)
	testing.expect_value(t, string(payload), "hello odin")
}

// Payloads >= 126 bytes use the 16-bit extended length.
@(test)
test_websocket_echo_medium_binary :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	data := make([]byte, 1000, context.temp_allocator)
	for i in 0 ..< len(data) {
		data[i] = u8(i)
	}
	test_ws_send_frame(&c, WS_OPCODE_BINARY, data)
	opcode, payload, _ := test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_BINARY)
	testing.expect_value(t, len(payload), 1000)
	testing.expect_value(t, payload[999], u8(999 % 256))
}

// One message in three frames: TEXT(fin=0) + CONTINUATION(fin=0) + CONTINUATION(fin=1),
// with a PING in the middle (control frames may interleave).
@(test)
test_websocket_fragmented_message :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	test_ws_send_frame(&c, WS_OPCODE_TEXT, transmute([]byte)string("frag"), fin = false)
	test_ws_send_frame(&c, WS_OPCODE_CONTINUATION, transmute([]byte)string("men"), fin = false)
	test_ws_send_frame(&c, WS_OPCODE_PING, transmute([]byte)string("p"))
	test_ws_send_frame(&c, WS_OPCODE_CONTINUATION, transmute([]byte)string("ted"), fin = true)

	// First the pong (answered immediately), then the reassembled echo.
	opcode, payload, _ := test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_PONG)
	testing.expect_value(t, string(payload), "p")

	opcode, payload, _ = test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_TEXT)
	testing.expect_value(t, string(payload), "fragmented")
}

@(test)
test_websocket_close_handshake :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	// Close with status 1000 (big-endian 0x03E8).
	test_ws_send_frame(&c, WS_OPCODE_CLOSE, []byte{0x03, 0xE8})
	opcode, payload, _ := test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_CLOSE)
	testing.expect_value(t, len(payload), 2)
	testing.expect_value(t, u16(payload[0]) << 8 | u16(payload[1]), WS_CLOSE_NORMAL)
	// ...and then the server closes the TCP connection.
	testing.expect_value(t, conn_fill(&c), false)
}

// Clients MUST mask their frames; the server must fail the connection (1002).
@(test)
test_websocket_unmasked_frame_is_protocol_error :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	test_ws_send_frame(&c, WS_OPCODE_TEXT, transmute([]byte)string("hi"), masked = false)
	opcode, payload, _ := test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_CLOSE)
	testing.expect_value(t, u16(payload[0]) << 8 | u16(payload[1]), WS_CLOSE_PROTOCOL_ERROR)
}

@(test)
test_websocket_invalid_utf8_text :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&c)

	test_ws_send_frame(&c, WS_OPCODE_TEXT, []byte{0xFF, 0xFE})
	opcode, payload, _ := test_ws_read_frame(&c)
	testing.expect_value(t, opcode, WS_OPCODE_CLOSE)
	testing.expect_value(t, u16(payload[0]) << 8 | u16(payload[1]), WS_CLOSE_INVALID_DATA)
}

// The integration between the three parts: a REST call on one connection
// produces a WebSocket message on another.
@(test)
test_websocket_receives_broadcast_from_rest :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	ws, ok := test_ws_connect(t, s)
	if !ok do return
	defer test_close(&ws)

	resp, _ := test_http_do(t, s, "POST", "/notes", `{"title":"live","body":"update"}`)
	testing.expect_value(t, resp.status, 201)

	opcode, payload, _ := test_ws_read_frame(&ws)
	testing.expect_value(t, opcode, WS_OPCODE_TEXT)
	testing.expect_value(t, string(payload), `{"event":"note_created","note":{"id":1,"title":"live","body":"update"}}`)
}

// A plain GET /ws (no Upgrade header) is not a WebSocket request.
@(test)
test_websocket_endpoint_without_upgrade :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	resp, _ := test_http_do(t, s, "GET", "/ws")
	testing.expect_value(t, resp.status, 426)
}
