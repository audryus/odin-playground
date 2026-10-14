package server

// =============================================================================
// http1.odin - HTTP/1.1 by hand (RFC 9112).
//
// An HTTP/1.1 request on the wire looks like this (\r\n = CRLF):
//
//     POST /notes HTTP/1.1\r\n            <- request line: METHOD TARGET VERSION
//     Host: localhost:8080\r\n            <- headers: "Name: value"
//     Content-Type: application/json\r\n
//     Content-Length: 27\r\n              <- tells us how many body bytes follow
//     \r\n                                <- empty line = end of headers
//     {"title":"hi","body":"yo"}          <- body (exactly Content-Length bytes)
//
// And a response:
//
//     HTTP/1.1 201 Created\r\n            <- status line: VERSION CODE REASON
//     Content-Type: application/json\r\n
//     Content-Length: 37\r\n
//     \r\n
//     {"id":1,"title":"hi","body":"yo"}
//
// HTTP/1.1 connections are "keep-alive" by default: after a response, the
// client may send another request on the same TCP connection. So http1_serve
// is a loop: read request, route, write response, repeat.
//
// What's NOT supported (on purpose, to keep it small): chunked request bodies,
// pipelining edge cases, "Expect: 100-continue", TLS.
// =============================================================================

import "core:fmt"
import "core:strconv"
import "core:strings"

MAX_HEADER_BYTES :: 16 * 1024   // request line + headers
MAX_BODY_BYTES   :: 1024 * 1024 // 1 MiB

Header :: struct {
	name:  string,
	value: string,
}

// Request is a parsed HTTP/1.1 request. All its strings live in
// context.temp_allocator, which is freed after each request.
Request :: struct {
	method:  string, // "GET"
	target:  string, // "/notes/1?verbose=1" (raw, as received)
	path:    string, // "/notes/1"
	query:   string, // "verbose=1"
	version: string, // "HTTP/1.1"
	headers: [dynamic]Header,
	body:    []byte,
}

// Response is what a handler fills in. It is NOT written to the socket by the
// handler: the caller serializes it afterwards (http1_write_response).
//
// This split is what makes handlers testable without any socket, the same idea
// as Go's httptest.ResponseRecorder: a test builds a Request by hand, calls
// the handler, and inspects the Response. See handlers_test.odin.
Response :: struct {
	status:  int,
	headers: [dynamic]Header,
	body:    [dynamic]byte,
}

Read_Result :: enum {
	Ok,
	Closed,            // the client closed the connection (normal end)
	Bad_Request,       // 400
	Headers_Too_Large, // 431
	Body_Too_Large,    // 413
	Not_Implemented,   // 501 (e.g. chunked request bodies)
}

// header_get finds a header by name. Header names are case-INsensitive in
// HTTP, so "content-length" must match "Content-Length".
header_get :: proc(headers: []Header, name: string) -> (value: string, found: bool) {
	for h in headers {
		if strings.equal_fold(h.name, name) {
			return h.value, true
		}
	}
	return "", false
}

// http1_read_request reads ONE request from the connection.
http1_read_request :: proc(c: ^Conn, req: ^Request) -> Read_Result {
	// --- 1. Find the end of the headers: the first "\r\n\r\n". -----------------
	head_length, found, too_large := conn_find(c, "\r\n\r\n", MAX_HEADER_BYTES)
	if too_large {
		return .Headers_Too_Large
	}
	if !found {
		return .Closed
	}
	head_bytes, _ := conn_take(c, head_length, context.temp_allocator)
	head := string(head_bytes[:head_length - 4]) // without the final \r\n\r\n

	// --- 2. Split into lines. Line 0 is the request line. ---------------------
	lines := strings.split(head, "\r\n", context.temp_allocator)

	request_line := strings.split(lines[0], " ", context.temp_allocator)
	if len(request_line) != 3 {
		return .Bad_Request
	}
	req.method = request_line[0]
	req.target = request_line[1]
	req.version = request_line[2]
	if req.version != "HTTP/1.1" && req.version != "HTTP/1.0" {
		return .Bad_Request
	}
	if !strings.has_prefix(req.target, "/") {
		return .Bad_Request
	}

	// "/notes?x=1" -> path "/notes", query "x=1"
	question_mark := strings.index_byte(req.target, '?')
	if question_mark >= 0 {
		req.path = req.target[:question_mark]
		req.query = req.target[question_mark + 1:]
	} else {
		req.path = req.target
		req.query = ""
	}

	// --- 3. Headers: "Name: value" ---------------------------------------------
	req.headers = make([dynamic]Header, 0, 16, context.temp_allocator)
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return .Bad_Request
		}
		name := line[:colon]
		value := strings.trim_space(line[colon + 1:])
		append(&req.headers, Header{name = name, value = value})
	}

	// --- 4. Body -----------------------------------------------------------------
	// Chunked bodies ("Transfer-Encoding: chunked") are a different framing;
	// we don't implement them in this POC.
	if _, chunked := header_get(req.headers[:], "Transfer-Encoding"); chunked {
		return .Not_Implemented
	}

	// Without Content-Length there is no body.
	content_length_text, has_length := header_get(req.headers[:], "Content-Length")
	if !has_length {
		req.body = nil
		return .Ok
	}
	content_length, ok := strconv.parse_int(content_length_text, 10)
	if !ok || content_length < 0 {
		return .Bad_Request
	}
	if content_length > MAX_BODY_BYTES {
		return .Body_Too_Large
	}
	body, body_ok := conn_take(c, content_length, context.temp_allocator)
	if !body_ok {
		return .Closed
	}
	req.body = body
	return .Ok
}

// status_text is the human readable "reason phrase" of the status line.
status_text :: proc(status: int) -> string {
	switch status {
	case 101: return "Switching Protocols"
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 400: return "Bad Request"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 413: return "Content Too Large"
	case 415: return "Unsupported Media Type"
	case 426: return "Upgrade Required"
	case 431: return "Request Header Fields Too Large"
	case 500: return "Internal Server Error"
	case 501: return "Not Implemented"
	}
	return "Unknown"
}

// http1_write_response serializes a Response and sends it.
http1_write_response :: proc(c: ^Conn, resp: ^Response, keep_alive: bool) -> bool {
	sb := strings.builder_make(context.temp_allocator)

	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", resp.status, status_text(resp.status))
	for h in resp.headers {
		fmt.sbprintf(&sb, "%s: %s\r\n", h.name, h.value)
	}
	// Content-Length is always sent: it's how the client knows where this
	// response ends and the next one (on the same connection) begins.
	fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(resp.body))
	if !keep_alive {
		strings.write_string(&sb, "Connection: close\r\n")
	}
	strings.write_string(&sb, "\r\n")
	strings.write_bytes(&sb, resp.body[:])

	return conn_send(c, sb.buf[:])
}

// http1_write_error is used when we couldn't even parse the request, so there
// is no Request/Response pair. We always close the connection afterwards
// because we don't know where the next request would begin.
http1_write_error :: proc(c: ^Conn, status: int) {
	resp := Response{status = status}
	resp.headers = make([dynamic]Header, context.temp_allocator)
	resp.body = make([dynamic]byte, context.temp_allocator)
	write_json_error(&resp, status, status_text(status))
	http1_write_response(c, &resp, keep_alive = false)
}

// should_keep_alive applies the HTTP rules:
//   HTTP/1.1: keep-alive unless the client says "Connection: close"
//   HTTP/1.0: close unless the client says "Connection: keep-alive"
should_keep_alive :: proc(req: ^Request) -> bool {
	connection, _ := header_get(req.headers[:], "Connection")
	if req.version == "HTTP/1.0" {
		return strings.equal_fold(connection, "keep-alive")
	}
	return !strings.equal_fold(connection, "close")
}

// http1_serve is the request loop of one HTTP/1.1 connection.
http1_serve :: proc(s: ^Server, c: ^Conn) {
	for {
		// Everything of the previous request (parsed strings, JSON, response
		// bytes...) was in the temp allocator. Drop it all at once.
		free_all(context.temp_allocator)

		req: Request
		result := http1_read_request(c, &req)
		switch result {
		case .Ok:
		// continue below
		case .Closed:
			return
		case .Bad_Request:
			http1_write_error(c, 400)
			return
		case .Headers_Too_Large:
			http1_write_error(c, 431)
			return
		case .Body_Too_Large:
			http1_write_error(c, 413)
			return
		case .Not_Implemented:
			http1_write_error(c, 501)
			return
		}

		// WebSocket: the request is a normal HTTP GET with "Upgrade: websocket".
		// If accepted, the connection stops being HTTP and becomes a WebSocket.
		// websocket_serve takes over the connection until it's closed.
		if websocket_is_upgrade_request(&req) {
			websocket_serve(s, c, &req)
			return
		}

		resp := Response{status = 200}
		resp.headers = make([dynamic]Header, 0, 8, context.temp_allocator)
		resp.body = make([dynamic]byte, 0, 256, context.temp_allocator)

		route(s, &req, &resp)

		keep_alive := should_keep_alive(&req)
		if !http1_write_response(c, &resp, keep_alive) {
			return
		}
		if !keep_alive {
			return
		}
	}
}

// =============================================================================
// Router. Deliberately just a chain of `if`s: no route table, no patterns,
// no middleware. You can read top to bottom which handler runs.
//
//   GET    /health       -> handle_health
//   GET    /notes        -> handle_list_notes
//   POST   /notes        -> handle_create_note
//   GET    /notes/{id}   -> handle_get_note
//   PUT    /notes/{id}   -> handle_update_note
//   DELETE /notes/{id}   -> handle_delete_note
//   GET    /ws           -> WebSocket (handled before routing, see http1_serve)
// =============================================================================
route :: proc(s: ^Server, req: ^Request, resp: ^Response) {
	if req.path == "/health" {
		if req.method == "GET" {
			handle_health(s, req, resp)
		} else {
			write_method_not_allowed(resp, "GET")
		}
		return
	}

	if req.path == "/notes" {
		switch req.method {
		case "GET":
			handle_list_notes(s, req, resp)
		case "POST":
			handle_create_note(s, req, resp)
		case:
			write_method_not_allowed(resp, "GET, POST")
		}
		return
	}

	if strings.has_prefix(req.path, "/notes/") {
		id_text := req.path[len("/notes/"):]
		id, ok := strconv.parse_i64(id_text, 10)
		if !ok || id <= 0 {
			write_json_error(resp, 400, "invalid note id")
			return
		}
		switch req.method {
		case "GET":
			handle_get_note(s, req, resp, id)
		case "PUT":
			handle_update_note(s, req, resp, id)
		case "DELETE":
			handle_delete_note(s, req, resp, id)
		case:
			write_method_not_allowed(resp, "GET, PUT, DELETE")
		}
		return
	}

	// /ws without the Upgrade headers is a plain HTTP request to a WebSocket
	// endpoint: tell the client it must upgrade.
	if req.path == "/ws" {
		append(&resp.headers, Header{"Upgrade", "websocket"})
		write_json_error(resp, 426, "this endpoint only speaks WebSocket")
		return
	}

	write_json_error(resp, 404, "not found")
}

write_method_not_allowed :: proc(resp: ^Response, allowed: string) {
	// The Allow header is mandatory with a 405 (RFC 9110, 15.5.6).
	append(&resp.headers, Header{"Allow", allowed})
	write_json_error(resp, 405, "method not allowed")
}
