package server

// =============================================================================
// grpc.odin - the gRPC endpoint: notes.v1.NotesService/GetNote.
//
// gRPC is "just" a convention on top of HTTP/2 (see the spec "gRPC over HTTP2",
// https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md):
//
//   REQUEST
//     HEADERS  :method = POST
//              :path   = /<package>.<Service>/<Method>   e.g. /notes.v1.NotesService/GetNote
//              content-type = application/grpc  (or application/grpc+proto)
//              te = trailers
//     DATA     length-prefixed message (see below)
//
//   RESPONSE
//     HEADERS  :status = 200, content-type = application/grpc
//     DATA     length-prefixed message
//     HEADERS  (TRAILERS, with END_STREAM)  grpc-status = 0, grpc-message = ...
//
// The RESULT of the call is in the trailers (grpc-status), NOT in :status.
// :status is 200 even when the call fails with NOT_FOUND. When there's an
// error and no message, the server may send a single "Trailers-Only" HEADERS
// frame that has :status, content-type AND grpc-status together.
//
// Length-prefixed message (5-byte header + protobuf bytes):
//
//     +------------+---------------------------+---------------------+
//     | compressed |   message length (u32,    |  protobuf message   |
//     |  (1 byte)  |   big-endian, 4 bytes)    |  (length bytes)     |
//     +------------+---------------------------+---------------------+
// =============================================================================

import "core:fmt"
import "core:log"
import "core:strings"

GRPC_GET_NOTE_PATH :: "/notes.v1.NotesService/GetNote"

// gRPC status codes (a subset). https://grpc.io/docs/guides/status-codes/
GRPC_STATUS_OK               :: 0
GRPC_STATUS_INVALID_ARGUMENT :: 3
GRPC_STATUS_NOT_FOUND        :: 5
GRPC_STATUS_UNIMPLEMENTED    :: 12
GRPC_STATUS_INTERNAL         :: 13

// grpc_handle_stream is called by http2.odin when a request is complete.
// Returns false if the connection broke while writing.
grpc_handle_stream :: proc(s: ^Server, h2: ^H2_Conn, stream: ^H2_Stream) -> bool {
	method := h2_stream_header(stream, ":method")
	path := h2_stream_header(stream, ":path")
	content_type := h2_stream_header(stream, "content-type")
	log.debugf("grpc: %s %s (%s)", method, path, content_type)

	// Not a gRPC request at all -> plain HTTP errors.
	if method != "POST" {
		return h2_write_headers(h2, stream.id, {{":status", "405"}}, end_stream = true)
	}
	if !strings.has_prefix(content_type, "application/grpc") {
		return h2_write_headers(h2, stream.id, {{":status", "415"}}, end_stream = true)
	}

	// A gRPC request for a method we don't have.
	if path != GRPC_GET_NOTE_PATH {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_UNIMPLEMENTED, fmt.tprintf("unknown method %s", path))
	}

	// --- Unwrap the length-prefixed message -----------------------------------------
	body := stream.body[:]
	if len(body) < 5 {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_INVALID_ARGUMENT, "missing request message")
	}
	compressed := body[0]
	message_length := int(body[1]) << 24 | int(body[2]) << 16 | int(body[3]) << 8 | int(body[4])
	if compressed != 0 {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_UNIMPLEMENTED, "compression is not supported")
	}
	// Unary call: exactly ONE message in the body.
	if 5 + message_length != len(body) {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_INVALID_ARGUMENT, "malformed request message")
	}
	message := body[5:]

	// --- Decode protobuf, run the "business logic" ------------------------------------
	request, decoded := pb_decode_get_note_request(message)
	if !decoded {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_INVALID_ARGUMENT, "invalid GetNoteRequest")
	}
	note, found := notes_get_copy(s, request.id, context.temp_allocator)
	if !found {
		return grpc_write_error(h2, stream.id, GRPC_STATUS_NOT_FOUND, fmt.tprintf("note %d not found", request.id))
	}

	// --- Encode the response: 5-byte prefix + protobuf --------------------------------
	reply := pb_encode_note(note, context.temp_allocator)
	framed := make([]byte, 5 + len(reply), context.temp_allocator)
	framed[0] = 0 // not compressed
	framed[1] = u8(len(reply) >> 24)
	framed[2] = u8(len(reply) >> 16)
	framed[3] = u8(len(reply) >> 8)
	framed[4] = u8(len(reply))
	copy(framed[5:], reply)

	// --- HEADERS, DATA, TRAILERS -----------------------------------------------------------
	h2_write_headers(h2, stream.id, {{":status", "200"}, {"content-type", "application/grpc"}}, end_stream = false) or_return
	h2_write_data(h2, stream.id, framed, end_stream = false) or_return
	return h2_write_headers(h2, stream.id, {{"grpc-status", "0"}}, end_stream = true)
}

// grpc_write_error sends a "Trailers-Only" response: one HEADERS frame with
// both the HTTP status and the gRPC status, and END_STREAM.
//
// (Strictly, grpc-message must be percent-encoded. Ours are plain ASCII
// without '%', so they're already valid.)
grpc_write_error :: proc(h2: ^H2_Conn, stream_id: u32, status: int, message: string) -> bool {
	headers := []Header{
		{":status", "200"},
		{"content-type", "application/grpc"},
		{"grpc-status", fmt.tprintf("%d", status)},
		{"grpc-message", message},
	}
	return h2_write_headers(h2, stream_id, headers, end_stream = true)
}
