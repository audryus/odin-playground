package server

// =============================================================================
// protobuf.odin - Protocol Buffers wire format by hand.
//
// The schema lives in ../proto/notes.proto. There is no protoc plugin for
// Odin, so instead of generated code we write the encode/decode procs
// ourselves. It's surprisingly little code once you know the format.
//
// A protobuf message is just a sequence of fields:
//
//     [key][value] [key][value] [key][value] ...
//
//   key   = varint( (field_number << 3) | wire_type )
//   value = depends on the wire type:
//
//     wire type 0  VARINT  int32, int64, uint64, bool, enum  -> a varint
//     wire type 1  I64     fixed64, double                   -> 8 bytes little-endian
//     wire type 2  LEN     string, bytes, sub-messages       -> varint length + bytes
//     wire type 5  I32     fixed32, float                    -> 4 bytes little-endian
//
// VARINT = 7 bits per byte, least significant group first, high bit (0x80)
// set on every byte except the last. Examples:
//
//     1   -> 01
//     150 -> 96 01        (150 = 0b1_0010110 -> [1 0010110] [0000001])
//
// Example: Note{id: 1, title: "hi"} encodes to
//
//     08 01          field 1, wire 0 (08 = 1<<3|0), value 1
//     12 02 68 69    field 2, wire 2 (12 = 2<<3|2), length 2, "hi"
//
// proto3 rules we follow: fields with the default value (0, "") are not
// written at all, and decoders must SKIP unknown fields (that's how old and
// new versions of a schema stay compatible).
// =============================================================================

PB_WIRE_VARINT :: 0
PB_WIRE_I64    :: 1
PB_WIRE_LEN    :: 2
PB_WIRE_I32    :: 5

// message GetNoteRequest { int64 id = 1; }
Get_Note_Request :: struct {
	id: i64,
}

// message Note { int64 id = 1; string title = 2; string body = 3; }
// -> we reuse the REST `Note` struct (rest.odin), it has the same fields.

// -----------------------------------------------------------------------------
// Low level: varints, keys, skipping
// -----------------------------------------------------------------------------

pb_append_varint :: proc(buf: ^[dynamic]byte, value: u64) {
	v := value
	for v >= 0x80 {
		append(buf, u8(v & 0x7F) | 0x80) // 7 bits + "more bytes follow"
		v >>= 7
	}
	append(buf, u8(v)) // last byte, high bit clear
}

pb_read_varint :: proc(data: []byte, pos: ^int) -> (value: u64, ok: bool) {
	shift: uint = 0
	for _ in 0 ..< 10 { // a u64 needs at most 10 varint bytes
		if pos^ >= len(data) {
			return 0, false
		}
		b := data[pos^]
		pos^ += 1
		value |= u64(b & 0x7F) << shift
		if b & 0x80 == 0 {
			return value, true
		}
		shift += 7
	}
	return 0, false // more than 10 bytes: malformed
}

pb_append_key :: proc(buf: ^[dynamic]byte, field_number: u64, wire_type: u64) {
	pb_append_varint(buf, field_number << 3 | wire_type)
}

pb_append_int64_field :: proc(buf: ^[dynamic]byte, field_number: u64, value: i64) {
	if value == 0 {
		return // proto3 default value: omitted
	}
	pb_append_key(buf, field_number, PB_WIRE_VARINT)
	// Negative int64 are sent as their two's complement u64 (10 bytes).
	pb_append_varint(buf, u64(value))
}

pb_append_string_field :: proc(buf: ^[dynamic]byte, field_number: u64, value: string) {
	if len(value) == 0 {
		return // proto3 default value: omitted
	}
	pb_append_key(buf, field_number, PB_WIRE_LEN)
	pb_append_varint(buf, u64(len(value)))
	append(buf, value)
}

// pb_read_len_bytes reads a LEN value and returns a slice INTO data (no copy).
pb_read_len_bytes :: proc(data: []byte, pos: ^int) -> (value: []byte, ok: bool) {
	length := pb_read_varint(data, pos) or_return
	if length > u64(len(data) - pos^) {
		return nil, false
	}
	value = data[pos^:][:length]
	pos^ += int(length)
	return value, true
}

// pb_skip_field jumps over a field we don't know.
pb_skip_field :: proc(data: []byte, pos: ^int, wire_type: u64) -> bool {
	switch wire_type {
	case PB_WIRE_VARINT:
		_, ok := pb_read_varint(data, pos)
		return ok
	case PB_WIRE_I64:
		pos^ += 8
	case PB_WIRE_LEN:
		_, ok := pb_read_len_bytes(data, pos)
		return ok
	case PB_WIRE_I32:
		pos^ += 4
	case:
		return false // 3 and 4 are the deprecated "groups"; unsupported
	}
	return pos^ <= len(data)
}

// pb_read_key splits a key into field number and wire type.
pb_read_key :: proc(data: []byte, pos: ^int) -> (field_number: u64, wire_type: u64, ok: bool) {
	key := pb_read_varint(data, pos) or_return
	field_number = key >> 3
	wire_type = key & 0x7
	if field_number == 0 {
		return 0, 0, false // field 0 is invalid
	}
	return field_number, wire_type, true
}

// -----------------------------------------------------------------------------
// GetNoteRequest
// -----------------------------------------------------------------------------

pb_encode_get_note_request :: proc(msg: Get_Note_Request, allocator := context.allocator) -> []byte {
	buf := make([dynamic]byte, 0, 16, allocator)
	pb_append_int64_field(&buf, 1, msg.id)
	return buf[:]
}

pb_decode_get_note_request :: proc(data: []byte) -> (msg: Get_Note_Request, ok: bool) {
	pos := 0
	for pos < len(data) {
		field_number, wire_type := pb_read_key(data, &pos) or_return
		switch field_number {
		case 1:
			if wire_type != PB_WIRE_VARINT {
				return {}, false
			}
			value := pb_read_varint(data, &pos) or_return
			msg.id = i64(value)
		case:
			pb_skip_field(data, &pos, wire_type) or_return
		}
	}
	return msg, true
}

// -----------------------------------------------------------------------------
// Note
// -----------------------------------------------------------------------------

pb_encode_note :: proc(note: Note, allocator := context.allocator) -> []byte {
	buf := make([dynamic]byte, 0, 32 + len(note.title) + len(note.body), allocator)
	pb_append_int64_field(&buf, 1, note.id)
	pb_append_string_field(&buf, 2, note.title)
	pb_append_string_field(&buf, 3, note.body)
	return buf[:]
}

// pb_decode_note: the returned strings point INTO `data` (no allocation), so
// `data` must outlive the Note. Used by the tests / client side.
pb_decode_note :: proc(data: []byte) -> (note: Note, ok: bool) {
	pos := 0
	for pos < len(data) {
		field_number, wire_type := pb_read_key(data, &pos) or_return
		switch field_number {
		case 1:
			if wire_type != PB_WIRE_VARINT {
				return {}, false
			}
			value := pb_read_varint(data, &pos) or_return
			note.id = i64(value)
		case 2:
			if wire_type != PB_WIRE_LEN {
				return {}, false
			}
			value := pb_read_len_bytes(data, &pos) or_return
			note.title = string(value)
		case 3:
			if wire_type != PB_WIRE_LEN {
				return {}, false
			}
			value := pb_read_len_bytes(data, &pos) or_return
			note.body = string(value)
		case:
			pb_skip_field(data, &pos, wire_type) or_return
		}
	}
	return note, true
}
