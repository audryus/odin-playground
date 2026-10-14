package server

// =============================================================================
// grpc_test.odin - protobuf, HPACK and gRPC-over-HTTP/2.
//
// Unit tests use the examples printed in the RFCs (RFC 7541 Appendix C for
// HPACK): if our code decodes the RFC's bytes into the RFC's headers, it's
// right. Then end-to-end tests make real gRPC calls over a socket.
// =============================================================================

import "core:testing"

// -----------------------------------------------------------------------------
// protobuf
// -----------------------------------------------------------------------------

@(test)
test_protobuf_varint :: proc(t: ^testing.T) {
	cases := []struct {
		value: u64,
		bytes: []byte,
	}{
		{0, {0x00}},
		{1, {0x01}},
		{150, {0x96, 0x01}}, // the example from protobuf.dev/programming-guides/encoding
		{300, {0xAC, 0x02}},
		{max(u64), {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01}},
	}
	for c in cases {
		buf := make([dynamic]byte, context.temp_allocator)
		pb_append_varint(&buf, c.value)
		testing.expectf(t, string(buf[:]) == string(c.bytes), "encode %d: got %x, want %x", c.value, buf[:], c.bytes)

		pos := 0
		decoded, ok := pb_read_varint(c.bytes, &pos)
		testing.expectf(t, ok && decoded == c.value && pos == len(c.bytes), "decode %x: got %d", c.bytes, decoded)
	}
}

@(test)
test_protobuf_note_bytes :: proc(t: ^testing.T) {
	encoded := pb_encode_note(Note{id = 1, title = "hi", body = ""}, context.temp_allocator)
	// 08 01        field 1 varint = 1
	// 12 02 68 69  field 2 len 2 = "hi"
	// (body is "" -> omitted, proto3 default)
	expected := []byte{0x08, 0x01, 0x12, 0x02, 'h', 'i'}
	testing.expect_value(t, string(encoded), string(expected))
}

@(test)
test_protobuf_note_roundtrip :: proc(t: ^testing.T) {
	original := Note{id = 123456789, title = "título com acento", body = "body\nwith\nlines"}
	encoded := pb_encode_note(original, context.temp_allocator)
	decoded, ok := pb_decode_note(encoded)
	testing.expect(t, ok)
	testing.expect_value(t, decoded, original)
}

// A newer client may send fields we don't know: they must be skipped.
@(test)
test_protobuf_skips_unknown_fields :: proc(t: ^testing.T) {
	data := []byte{
		0x28, 0x07,             // field 5, varint 7        (unknown)
		0x32, 0x03, 'a', 'b', 'c', // field 6, len 3 "abc"   (unknown)
		0x08, 0x2A,             // field 1, varint 42       (id)
		0x3D, 1, 2, 3, 4,       // field 7, fixed32         (unknown)
	}
	request, ok := pb_decode_get_note_request(data)
	testing.expect(t, ok)
	testing.expect_value(t, request.id, 42)
}

@(test)
test_protobuf_truncated_input_fails :: proc(t: ^testing.T) {
	_, ok := pb_decode_note([]byte{0x12, 0x05, 'a', 'b'}) // says 5 bytes, has 2
	testing.expect_value(t, ok, false)
}

// -----------------------------------------------------------------------------
// HPACK
// -----------------------------------------------------------------------------

// RFC 7541, C.1: integer representation examples.
@(test)
test_hpack_integers :: proc(t: ^testing.T) {
	cases := []struct {
		value:       int,
		prefix_bits: uint,
		bytes:       []byte,
	}{
		{10, 5, {0x0A}},             // C.1.1
		{1337, 5, {0x1F, 0x9A, 0x0A}}, // C.1.2
		{42, 8, {0x2A}},             // C.1.3
	}
	for c in cases {
		buf := make([dynamic]byte, context.temp_allocator)
		hpack_append_integer(&buf, 0, c.prefix_bits, c.value)
		testing.expectf(t, string(buf[:]) == string(c.bytes), "encode %d: got %x", c.value, buf[:])

		pos := 0
		value, ok := hpack_decode_integer(c.bytes, &pos, c.prefix_bits)
		testing.expectf(t, ok && value == c.value, "decode %x: got %d", c.bytes, value)
	}
}

// RFC 7541, C.4: Huffman-coded strings.
@(test)
test_huffman_decode :: proc(t: ^testing.T) {
	cases := []struct {
		encoded: []byte,
		decoded: string,
	}{
		{{0xF1, 0xE3, 0xC2, 0xE5, 0xF2, 0x3A, 0x6B, 0xA0, 0xAB, 0x90, 0xF4, 0xFF}, "www.example.com"},
		{{0xA8, 0xEB, 0x10, 0x64, 0x9C, 0xBF}, "no-cache"},
		{{0x25, 0xA8, 0x49, 0xE9, 0x5B, 0xA9, 0x7D, 0x7F}, "custom-key"},
		{{0x25, 0xA8, 0x49, 0xE9, 0x5B, 0xB8, 0xE8, 0xB4, 0xBF}, "custom-value"},
	}
	for c in cases {
		s, ok := huffman_decode(c.encoded, context.temp_allocator)
		testing.expectf(t, ok && s == c.decoded, "huffman %x: got %q, want %q", c.encoded, s, c.decoded)
	}

	// Padding longer than 7 bits is invalid.
	_, ok := huffman_decode([]byte{0xFF, 0xFF}, context.temp_allocator)
	testing.expect_value(t, ok, false)
}

// RFC 7541, C.3: three requests on the same connection, WITHOUT Huffman.
// The second and third reuse entries the first one added to the dynamic table.
@(test)
test_hpack_decode_rfc_requests :: proc(t: ^testing.T) {
	d: Hpack_Decoder
	hpack_decoder_init(&d)
	defer hpack_decoder_destroy(&d)

	// C.3.1
	{
		block := []byte{
			0x82, 0x86, 0x84, 0x41, 0x0F, 0x77, 0x77, 0x77, 0x2E, 0x65, 0x78, 0x61,
			0x6D, 0x70, 0x6C, 0x65, 0x2E, 0x63, 0x6F, 0x6D,
		}
		headers := make([dynamic]Header, context.temp_allocator)
		testing.expect(t, hpack_decode_block(&d, block, &headers, context.temp_allocator))
		testing.expect_value(t, len(headers), 4)
		testing.expect_value(t, headers[0], Header{":method", "GET"})
		testing.expect_value(t, headers[1], Header{":scheme", "http"})
		testing.expect_value(t, headers[2], Header{":path", "/"})
		testing.expect_value(t, headers[3], Header{":authority", "www.example.com"})
		testing.expect_value(t, d.size, 57) // the RFC states the table size after each step
	}
	// C.3.2: "be" = index 62 = the ":authority" entry added above.
	{
		block := []byte{0x82, 0x86, 0x84, 0xBE, 0x58, 0x08, 0x6E, 0x6F, 0x2D, 0x63, 0x61, 0x63, 0x68, 0x65}
		headers := make([dynamic]Header, context.temp_allocator)
		testing.expect(t, hpack_decode_block(&d, block, &headers, context.temp_allocator))
		testing.expect_value(t, len(headers), 5)
		testing.expect_value(t, headers[3], Header{":authority", "www.example.com"})
		testing.expect_value(t, headers[4], Header{"cache-control", "no-cache"})
		testing.expect_value(t, d.size, 110)
	}
	// C.3.3
	{
		block := []byte{
			0x82, 0x87, 0x85, 0xBF, 0x40, 0x0A, 0x63, 0x75, 0x73, 0x74, 0x6F, 0x6D,
			0x2D, 0x6B, 0x65, 0x79, 0x0C, 0x63, 0x75, 0x73, 0x74, 0x6F, 0x6D, 0x2D,
			0x76, 0x61, 0x6C, 0x75, 0x65,
		}
		headers := make([dynamic]Header, context.temp_allocator)
		testing.expect(t, hpack_decode_block(&d, block, &headers, context.temp_allocator))
		testing.expect_value(t, len(headers), 5)
		testing.expect_value(t, headers[0], Header{":method", "GET"})
		testing.expect_value(t, headers[1], Header{":scheme", "https"})
		testing.expect_value(t, headers[2], Header{":path", "/index.html"})
		testing.expect_value(t, headers[3], Header{":authority", "www.example.com"})
		testing.expect_value(t, headers[4], Header{"custom-key", "custom-value"})
		testing.expect_value(t, d.size, 164)
	}
}

// -----------------------------------------------------------------------------
// gRPC end to end
// -----------------------------------------------------------------------------

@(test)
test_grpc_get_note :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	// Create the note through REST...
	created, _ := test_http_do(t, s, "POST", "/notes", `{"title":"from rest","body":"read by grpc"}`)
	testing.expect_value(t, created.status, 201)

	// ...and read it through gRPC.
	client: Test_H2_Client
	if !test_h2_connect(t, s, &client) do return
	defer test_h2_close(&client)

	request := pb_encode_get_note_request(Get_Note_Request{id = 1}, context.temp_allocator)
	result, ok := test_grpc_call(&client, GRPC_GET_NOTE_PATH, request)
	testing.expect(t, ok)
	testing.expect_value(t, result.http_status, "200")
	testing.expect_value(t, result.grpc_status, "0")

	note, decoded := pb_decode_note(result.message)
	testing.expect(t, decoded)
	testing.expect_value(t, note, Note{id = 1, title = "from rest", body = "read by grpc"})
}

@(test)
test_grpc_get_note_not_found :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	client: Test_H2_Client
	if !test_h2_connect(t, s, &client) do return
	defer test_h2_close(&client)

	request := pb_encode_get_note_request(Get_Note_Request{id = 42}, context.temp_allocator)
	result, ok := test_grpc_call(&client, GRPC_GET_NOTE_PATH, request)
	testing.expect(t, ok)
	// gRPC errors still have HTTP status 200: the error is in grpc-status.
	testing.expect_value(t, result.http_status, "200")
	testing.expect_value(t, result.grpc_status, "5") // NOT_FOUND
	testing.expect_value(t, result.grpc_message, "note 42 not found")
	testing.expect_value(t, len(result.message), 0)
}

@(test)
test_grpc_unknown_method :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	client: Test_H2_Client
	if !test_h2_connect(t, s, &client) do return
	defer test_h2_close(&client)

	result, ok := test_grpc_call(&client, "/notes.v1.NotesService/DeleteEverything", nil)
	testing.expect(t, ok)
	testing.expect_value(t, result.grpc_status, "12") // UNIMPLEMENTED
}

// HTTP/2 multiplexing in its simplest form: several calls, one connection,
// stream ids 1, 3, 5.
@(test)
test_grpc_several_calls_one_connection :: proc(t: ^testing.T) {
	s := test_server_start(t)
	if s == nil do return
	defer test_server_stop(s)

	test_http_do(t, s, "POST", "/notes", `{"title":"one","body":""}`)
	test_http_do(t, s, "POST", "/notes", `{"title":"two","body":""}`)

	client: Test_H2_Client
	if !test_h2_connect(t, s, &client) do return
	defer test_h2_close(&client)

	expected := []string{"one", "two", "one"}
	ids := []i64{1, 2, 1}
	for id, i in ids {
		request := pb_encode_get_note_request(Get_Note_Request{id = id}, context.temp_allocator)
		result, ok := test_grpc_call(&client, GRPC_GET_NOTE_PATH, request)
		note, _ := pb_decode_note(result.message)
		testing.expectf(t, ok && result.grpc_status == "0" && note.title == expected[i], "call %d: status %q title %q", i, result.grpc_status, note.title)
	}
	testing.expect_value(t, client.next_stream_id, 7)
}
