package server

// =============================================================================
// helpers_test.odin - test helpers. Odin's version of Go's net/http/httptest.
//
// How tests work in Odin (compare with Go):
//
//   Go                                 Odin
//   ---------------------------------  ---------------------------------------
//   func TestX(t *testing.T)           @(test) test_x :: proc(t: ^testing.T)
//   t.Errorf / if got != want          testing.expect_value(t, got, want)
//   go test ./...                      odin test server   (or `make test`)
//   go test -run TestX                 odin test server -define:ODIN_TEST_NAMES=server.test_x
//   tests run in parallel by default   same (one thread per test)
//   -race                              no; but leaks ARE detected: every test
//                                      gets a tracking allocator and fails if
//                                      memory isn't freed
//
// Files ending in _test.odin are just regular files of the package: they can
// call private procs, like Go's "internal" tests (package server, not
// package server_test).
//
// The two httptest ideas, translated:
//
//   httptest.NewRecorder()  -> build a Request by hand, call route(), look at
//                              the Response struct. No sockets at all.
//                              (handlers_test.odin)
//
//   httptest.NewServer(h)   -> test_server_start(): a REAL server on
//                              127.0.0.1:0 (the OS picks a free port), and real
//                              TCP clients talking raw HTTP/1.1, WebSocket and
//                              HTTP/2 to it. (http_test.odin, websocket_test.odin,
//                              grpc_test.odin)
// =============================================================================

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// -----------------------------------------------------------------------------
// "httptest.NewServer"
// -----------------------------------------------------------------------------

test_server_start :: proc(t: ^testing.T) -> ^Server {
	// Never let a buggy test hang forever.
	testing.set_fail_timeout(t, 10 * time.Second)

	s := new(Server)
	err := server_start(s, net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expectf(t, err == nil, "server_start failed: %v", err) {
		free(s)
		return nil
	}
	return s
}

test_server_stop :: proc(s: ^Server) {
	server_stop(s)
	free(s)
}

// test_dial opens a TCP connection to the test server, wrapped in a Conn so
// the tests can reuse the same buffered reading code as the server.
test_dial :: proc(t: ^testing.T, s: ^Server) -> (c: Conn, ok: bool) {
	socket, err := net.dial_tcp(s.endpoint)
	if !testing.expectf(t, err == nil, "dial failed: %v", err) {
		return {}, false
	}
	// If the server doesn't answer, fail the read after 5s instead of hanging.
	net.set_option(socket, .Receive_Timeout, 5 * time.Second)
	return Conn{socket = socket}, true
}

test_close :: proc(c: ^Conn) {
	net.close(c.socket)
	delete(c.buf)
}

// -----------------------------------------------------------------------------
// "httptest.NewRecorder" helpers
// -----------------------------------------------------------------------------

// test_request builds a Request as if it had been parsed from the network.
test_request :: proc(method, path: string, body := "") -> Request {
	req := Request {
		method  = method,
		target  = path,
		path    = path,
		version = "HTTP/1.1",
		body    = transmute([]byte)body,
	}
	req.headers = make([dynamic]Header, context.temp_allocator)
	return req
}

// test_recorder is an empty Response, ready to be filled by a handler.
test_recorder :: proc() -> Response {
	resp := Response{status = 200}
	resp.headers = make([dynamic]Header, context.temp_allocator)
	resp.body = make([dynamic]byte, context.temp_allocator)
	return resp
}

// -----------------------------------------------------------------------------
// A tiny HTTP/1.1 client
// -----------------------------------------------------------------------------

Test_Response :: struct {
	status:  int,
	headers: [dynamic]Header,
	body:    string,
}

// test_http_send writes a request with Content-Length (and optional extra
// header lines, each ending in \r\n).
test_http_send :: proc(c: ^Conn, method, path: string, body := "", extra_headers := "") -> bool {
	request := fmt.tprintf(
		"%s %s HTTP/1.1\r\nHost: test\r\n%sContent-Length: %d\r\n\r\n%s",
		method, path, extra_headers, len(body), body,
	)
	return conn_send(c, transmute([]byte)request)
}

// test_http_read reads one response (status line, headers, Content-Length body).
// Everything is allocated in the temp allocator.
test_http_read :: proc(c: ^Conn) -> (resp: Test_Response, ok: bool) {
	head_length, found, _ := conn_find(c, "\r\n\r\n", 64 * 1024)
	if !found {
		return {}, false
	}
	head_bytes := conn_take(c, head_length, context.temp_allocator) or_return
	lines := strings.split(string(head_bytes[:head_length - 4]), "\r\n", context.temp_allocator)

	// "HTTP/1.1 200 OK" -> 200
	status_line := strings.split_n(lines[0], " ", 3, context.temp_allocator)
	if len(status_line) < 2 {
		return {}, false
	}
	resp.status = strconv.parse_int(status_line[1], 10) or_return

	resp.headers = make([dynamic]Header, context.temp_allocator)
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon > 0 {
			append(&resp.headers, Header{line[:colon], strings.trim_space(line[colon + 1:])})
		}
	}

	length_text, has_length := header_get(resp.headers[:], "Content-Length")
	if has_length {
		length := strconv.parse_int(length_text, 10) or_return
		body := conn_take(c, length, context.temp_allocator) or_return
		resp.body = string(body)
	}
	return resp, true
}

// test_http_do: open a connection, send one request, read the response, close.
test_http_do :: proc(t: ^testing.T, s: ^Server, method, path: string, body := "") -> (resp: Test_Response, ok: bool) {
	c := test_dial(t, s) or_return
	defer test_close(&c)
	if !test_http_send(&c, method, path, body) {
		return {}, false
	}
	return test_http_read(&c)
}

// -----------------------------------------------------------------------------
// A tiny WebSocket client
// -----------------------------------------------------------------------------

// The example key from RFC 6455 section 1.3, and its expected accept value.
TEST_WS_KEY    :: "dGhlIHNhbXBsZSBub25jZQ=="
TEST_WS_ACCEPT :: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

test_ws_connect :: proc(t: ^testing.T, s: ^Server) -> (c: Conn, ok: bool) {
	c = test_dial(t, s) or_return
	handshake := "GET /ws HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + TEST_WS_KEY + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
	conn_send(&c, transmute([]byte)string(handshake))

	resp, read_ok := test_http_read(&c)
	accept, _ := header_get(resp.headers[:], "Sec-WebSocket-Accept")
	if !testing.expect(t, read_ok) ||
	   !testing.expect_value(t, resp.status, 101) ||
	   !testing.expect_value(t, accept, TEST_WS_ACCEPT) {
		test_close(&c)
		return {}, false
	}
	return c, true
}

// test_ws_send_frame sends one frame. Clients must mask, so by default we do
// (with a fixed key, which is fine for tests).
test_ws_send_frame :: proc(c: ^Conn, opcode: u8, payload: []byte, fin := true, masked := true) {
	frame := make([dynamic]byte, context.temp_allocator)
	append(&frame, (fin ? 0x80 : 0x00) | opcode)

	mask_bit: u8 = masked ? 0x80 : 0x00
	if len(payload) < 126 {
		append(&frame, mask_bit | u8(len(payload)))
	} else {
		// 16-bit length is enough for our tests
		append(&frame, mask_bit | 126, u8(len(payload) >> 8), u8(len(payload)))
	}

	mask_key := [4]byte{0x11, 0x22, 0x33, 0x44}
	if masked {
		append(&frame, ..mask_key[:])
	}
	for b, i in payload {
		append(&frame, masked ? b ~ mask_key[i % 4] : b)
	}
	conn_send(c, frame[:])
}

// test_ws_read_frame reads one (unmasked) server frame.
test_ws_read_frame :: proc(c: ^Conn) -> (opcode: u8, payload: []byte, ok: bool) {
	head := conn_take(c, 2, context.temp_allocator) or_return
	opcode = head[0] & 0x0F
	length := int(head[1] & 0x7F)
	if length == 126 {
		ext := conn_take(c, 2, context.temp_allocator) or_return
		length = int(ext[0]) << 8 | int(ext[1])
	} else if length == 127 {
		ext := conn_take(c, 8, context.temp_allocator) or_return
		length = 0
		for b in ext {
			length = length << 8 | int(b)
		}
	}
	payload = conn_take(c, length, context.temp_allocator) or_return
	return opcode, payload, true
}

// -----------------------------------------------------------------------------
// A tiny HTTP/2 + gRPC client.
//
// It reuses the server's own frame and HPACK code (h2_write_frame,
// h2_read_frame, hpack_*), just from the other side of the wire. A test that
// uses an independent implementation is tools/grpc_client (grpc-go).
// -----------------------------------------------------------------------------

Test_H2_Client :: struct {
	conn:           Conn,
	h2:             H2_Conn, // only .conn is used, for h2_read_frame / h2_write_frame
	decoder:        Hpack_Decoder, // decodes the SERVER's header blocks
	next_stream_id: u32,
}

Test_Grpc_Result :: struct {
	http_status:  string,
	grpc_status:  string,
	grpc_message: string,
	message:      []byte, // the response protobuf, without the 5-byte prefix
}

test_h2_connect :: proc(t: ^testing.T, s: ^Server, client: ^Test_H2_Client) -> bool {
	client.conn = test_dial(t, s) or_return
	client.h2.conn = &client.conn
	hpack_decoder_init(&client.decoder)
	client.next_stream_id = 1

	// Preface + our (empty) SETTINGS.
	conn_send(&client.conn, transmute([]byte)string(H2_PREFACE))
	h2_write_frame(&client.h2, H2_FRAME_SETTINGS, 0, 0, nil)
	return true
}

test_h2_close :: proc(client: ^Test_H2_Client) {
	hpack_decoder_destroy(&client.decoder)
	test_close(&client.conn)
}

// test_grpc_call performs one unary call on a new stream.
test_grpc_call :: proc(client: ^Test_H2_Client, path: string, request: []byte) -> (result: Test_Grpc_Result, ok: bool) {
	stream_id := client.next_stream_id
	client.next_stream_id += 2 // client streams are odd: 1, 3, 5...

	// HEADERS: plain literals, no Huffman, no indexing.
	block := make([dynamic]byte, context.temp_allocator)
	hpack_append_literal(&block, ":method", "POST")
	hpack_append_literal(&block, ":scheme", "http")
	hpack_append_literal(&block, ":path", path)
	hpack_append_literal(&block, ":authority", "test")
	hpack_append_literal(&block, "content-type", "application/grpc")
	hpack_append_literal(&block, "te", "trailers")
	h2_write_frame(&client.h2, H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, stream_id, block[:])

	// DATA: 5-byte prefix + message, and END_STREAM (we're done sending).
	framed := make([dynamic]byte, context.temp_allocator)
	append(&framed, 0, u8(len(request) >> 24), u8(len(request) >> 16), u8(len(request) >> 8), u8(len(request)))
	append(&framed, ..request)
	h2_write_frame(&client.h2, H2_FRAME_DATA, H2_FLAG_END_STREAM, stream_id, framed[:])

	// Read frames until the server ends our stream.
	headers := make([dynamic]Header, context.temp_allocator)
	body := make([dynamic]byte, context.temp_allocator)
	for {
		frame := h2_read_frame(&client.h2) or_return
		switch frame.type {
		case H2_FRAME_SETTINGS:
			if frame.flags & H2_FLAG_ACK == 0 {
				h2_write_frame(&client.h2, H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, nil)
			}
		case H2_FRAME_HEADERS:
			if frame.stream_id == stream_id {
				hpack_decode_block(&client.decoder, frame.payload, &headers, context.temp_allocator) or_return
			}
		case H2_FRAME_DATA:
			if frame.stream_id == stream_id {
				append(&body, ..frame.payload)
			}
		case H2_FRAME_GOAWAY:
			return {}, false
		}
		if frame.stream_id == stream_id && frame.flags & H2_FLAG_END_STREAM != 0 {
			break
		}
	}

	for h in headers {
		switch h.name {
		case ":status":
			result.http_status = h.value
		case "grpc-status":
			result.grpc_status = h.value
		case "grpc-message":
			result.grpc_message = h.value
		}
	}
	if len(body) >= 5 {
		result.message = body[5:]
	}
	return result, true
}
