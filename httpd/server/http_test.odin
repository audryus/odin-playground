package server

// =============================================================================
// http_test.odin - REST over a REAL socket (the httptest.NewServer style).
//
// These tests cover what handler tests can't: request parsing from raw bytes,
// keep-alive, Content-Length framing, malformed input, and TCP fragmentation.
// =============================================================================

import "core:encoding/json"
import "core:testing"
import "core:time"

@(test)
test_http_health :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	resp, ok := test_http_do(t, s, "GET", "/health")
	testing.expect(t, ok)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.body, `{"status":"ok"}`)
}

@(test)
test_http_crud_flow :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	created, ok := test_http_do(t, s, "POST", "/notes", `{"title":"hello","body":"world"}`)
	testing.expect(t, ok)
	testing.expect_value(t, created.status, 201)

	note: Note
	testing.expect_value(t, json.unmarshal(transmute([]byte)created.body, &note, allocator = context.temp_allocator), nil)
	testing.expect_value(t, note.id, 1)

	got, _ := test_http_do(t, s, "GET", "/notes/1")
	testing.expect_value(t, got.status, 200)
	testing.expect_value(t, got.body, `{"id":1,"title":"hello","body":"world"}`)

	listed, _ := test_http_do(t, s, "GET", "/notes")
	testing.expect_value(t, listed.body, `[{"id":1,"title":"hello","body":"world"}]`)

	deleted, _ := test_http_do(t, s, "DELETE", "/notes/1")
	testing.expect_value(t, deleted.status, 204)
	testing.expect_value(t, deleted.body, "")

	missing, _ := test_http_do(t, s, "GET", "/notes/1")
	testing.expect_value(t, missing.status, 404)
}

// HTTP/1.1 keeps the connection open: several requests, one TCP connection.
@(test)
test_http_keep_alive :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	for i in 0 ..< 3 {
		testing.expect(t, test_http_send(&c, "GET", "/health"))
		resp, read_ok := test_http_read(&c)
		testing.expectf(t, read_ok && resp.status == 200, "request %d on the same connection failed", i)
	}
}

// "Connection: close" -> the server answers and then closes the socket.
@(test)
test_http_connection_close :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	test_http_send(&c, "GET", "/health", extra_headers = "Connection: close\r\n")
	resp, _ := test_http_read(&c)
	testing.expect_value(t, resp.status, 200)
	connection, _ := header_get(resp.headers[:], "Connection")
	testing.expect_value(t, connection, "close")

	// The next read sees end-of-stream: recv() returns 0 -> conn_fill false.
	testing.expect_value(t, conn_fill(&c), false)
}

// TCP may deliver a request in any number of pieces. Send it one byte at a
// time to prove the parser waits for the whole thing.
@(test)
test_http_request_split_in_tiny_pieces :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	request := "POST /notes HTTP/1.1\r\nHost: x\r\nContent-Length: 24\r\n\r\n{\"title\":\"a\",\"body\":\"b\"}"
	for i in 0 ..< len(request) {
		conn_send(&c, transmute([]byte)request[i:i + 1])
		if i % 10 == 0 {
			time.sleep(time.Millisecond) // give the server a chance to read partial data
		}
	}
	resp, _ := test_http_read(&c)
	testing.expect_value(t, resp.status, 201)
	testing.expect_value(t, resp.body, `{"id":1,"title":"a","body":"b"}`)
}

@(test)
test_http_malformed_request_line :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	conn_send(&c, transmute([]byte)string("THIS IS NOT HTTP\r\n\r\n"))
	resp, _ := test_http_read(&c)
	testing.expect_value(t, resp.status, 400)
}

@(test)
test_http_chunked_body_not_implemented :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	conn_send(&c, transmute([]byte)string("POST /notes HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
	resp, _ := test_http_read(&c)
	testing.expect_value(t, resp.status, 501)
}

@(test)
test_http_body_too_large :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	c, ok := test_dial(t, s)
	if !ok do return
	defer test_close(&c)

	// We only announce the size; the server must refuse before reading it.
	conn_send(&c, transmute([]byte)string("POST /notes HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"))
	resp, _ := test_http_read(&c)
	testing.expect_value(t, resp.status, 413)
}
