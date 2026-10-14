package server

// =============================================================================
// hpack.odin - HPACK, the header compression of HTTP/2 (RFC 7541).
//
// HTTP/2 doesn't send headers as text. It sends a compact binary "header
// block" built from a few instructions. Both sides keep the same TABLE of
// known headers, so a header can often be sent as just its table index:
//
//   Index space:
//     1..61   the STATIC table (fixed list in the RFC, e.g. 2 = ":method: GET")
//     62..    the DYNAMIC table (headers this connection sent before, newest first)
//
//   Instructions (first bits of a byte tell which one):
//     1xxxxxxx  Indexed Header Field          -> "header #N from the table"
//     01xxxxxx  Literal WITH incremental index-> header given here, and ADD it
//                                               to the dynamic table
//     0000xxxx  Literal WITHOUT indexing      -> header given here, don't add
//     0001xxxx  Literal NEVER indexed         -> same, but proxies must not index
//                                               it either (used for secrets)
//     001xxxxx  Dynamic Table Size Update
//
//   The "x" bits start an INTEGER with an N-bit prefix (see hpack_decode_integer)
//   and literal names/values are STRINGS: a length (7-bit prefix integer, the
//   top bit says "Huffman encoded") followed by the bytes.
//
// The decoder is STATEFUL: its dynamic table must evolve exactly like the
// client's encoder table, so EVERY header block of the connection must be
// decoded, in order, even for requests we're going to reject.
//
// Our encoder (for responses) is the laziest valid one: it never uses Huffman
// and never adds to the dynamic table, so the client's decoder table for our
// side stays empty. Totally allowed by the RFC.
// =============================================================================

import "core:mem"
import "core:strings"

HPACK_DEFAULT_TABLE_SIZE :: 4096 // SETTINGS_HEADER_TABLE_SIZE default

// RFC 7541, Appendix A. HPACK index i is HPACK_STATIC_TABLE[i - 1].
@(rodata)
HPACK_STATIC_TABLE := [61]Header{
	{":authority", ""},
	{":method", "GET"},
	{":method", "POST"},
	{":path", "/"},
	{":path", "/index.html"},
	{":scheme", "http"},
	{":scheme", "https"},
	{":status", "200"},
	{":status", "204"},
	{":status", "206"},
	{":status", "304"},
	{":status", "400"},
	{":status", "404"},
	{":status", "500"},
	{"accept-charset", ""},
	{"accept-encoding", "gzip, deflate"},
	{"accept-language", ""},
	{"accept-ranges", ""},
	{"accept", ""},
	{"access-control-allow-origin", ""},
	{"age", ""},
	{"allow", ""},
	{"authorization", ""},
	{"cache-control", ""},
	{"content-disposition", ""},
	{"content-encoding", ""},
	{"content-language", ""},
	{"content-length", ""},
	{"content-location", ""},
	{"content-range", ""},
	{"content-type", ""},
	{"cookie", ""},
	{"date", ""},
	{"etag", ""},
	{"expect", ""},
	{"expires", ""},
	{"from", ""},
	{"host", ""},
	{"if-match", ""},
	{"if-modified-since", ""},
	{"if-none-match", ""},
	{"if-range", ""},
	{"if-unmodified-since", ""},
	{"last-modified", ""},
	{"link", ""},
	{"location", ""},
	{"max-forwards", ""},
	{"proxy-authenticate", ""},
	{"proxy-authorization", ""},
	{"range", ""},
	{"referer", ""},
	{"refresh", ""},
	{"retry-after", ""},
	{"server", ""},
	{"set-cookie", ""},
	{"strict-transport-security", ""},
	{"transfer-encoding", ""},
	{"user-agent", ""},
	{"vary", ""},
	{"via", ""},
	{"www-authenticate", ""},
}

Hpack_Decoder :: struct {
	allocator: mem.Allocator, // owns the strings in `entries`
	entries:   [dynamic]Header, // dynamic table, entries[0] = newest = index 62
	size:      int, // current size, as defined by the RFC (see hpack_entry_size)
	max_size:  int,
}

hpack_decoder_init :: proc(d: ^Hpack_Decoder, allocator := context.allocator) {
	d.allocator = allocator
	d.entries = make([dynamic]Header, allocator)
	d.size = 0
	d.max_size = HPACK_DEFAULT_TABLE_SIZE
}

hpack_decoder_destroy :: proc(d: ^Hpack_Decoder) {
	for h in d.entries {
		delete(h.name, d.allocator)
		delete(h.value, d.allocator)
	}
	delete(d.entries)
}

// The RFC counts 32 extra bytes per entry (an estimate of the overhead).
hpack_entry_size :: proc(name, value: string) -> int {
	return len(name) + len(value) + 32
}

@(private)
hpack_evict_oldest :: proc(d: ^Hpack_Decoder) {
	oldest := pop(&d.entries) // the oldest entry is at the END
	d.size -= hpack_entry_size(oldest.name, oldest.value)
	delete(oldest.name, d.allocator)
	delete(oldest.value, d.allocator)
}

// hpack_table_add inserts a header at the front of the dynamic table,
// evicting old entries if the table would grow beyond max_size.
hpack_table_add :: proc(d: ^Hpack_Decoder, name, value: string) {
	entry_size := hpack_entry_size(name, value)
	for len(d.entries) > 0 && d.size + entry_size > d.max_size {
		hpack_evict_oldest(d)
	}
	// An entry larger than the whole table just empties the table (RFC 7541, 4.4).
	if entry_size > d.max_size {
		return
	}
	inject_at(&d.entries, 0, Header{strings.clone(name, d.allocator), strings.clone(value, d.allocator)})
	d.size += entry_size
}

// hpack_lookup resolves an index (1-based) in static + dynamic tables.
hpack_lookup :: proc(d: ^Hpack_Decoder, index: int) -> (h: Header, ok: bool) {
	if index <= 0 {
		return {}, false
	}
	if index <= len(HPACK_STATIC_TABLE) {
		return HPACK_STATIC_TABLE[index - 1], true
	}
	dynamic_index := index - len(HPACK_STATIC_TABLE) - 1
	if dynamic_index < len(d.entries) {
		return d.entries[dynamic_index], true
	}
	return {}, false
}

// hpack_decode_integer reads an integer with an N-bit prefix (RFC 7541, 5.1).
//
// The value starts in the low N bits of the current byte (the high bits of
// that byte belong to the instruction). If it fits (< 2^N - 1) that's it.
// Otherwise the prefix is all 1s and the rest follows as 7-bit groups,
// least significant first, high bit = "more bytes follow" (like a varint).
//
// Example with a 5-bit prefix: 1337 = 31 + 1306
//     xxx11111  10011010  00001010
//         31    +26       +10*128   = 31 + 26 + 1280 = 1337
hpack_decode_integer :: proc(data: []byte, pos: ^int, prefix_bits: uint) -> (value: int, ok: bool) {
	if pos^ >= len(data) {
		return 0, false
	}
	max_prefix := (1 << prefix_bits) - 1
	value = int(data[pos^]) & max_prefix
	pos^ += 1
	if value < max_prefix {
		return value, true
	}
	shift: uint = 0
	for {
		if pos^ >= len(data) {
			return 0, false
		}
		b := data[pos^]
		pos^ += 1
		value += int(b & 0x7F) << shift
		shift += 7
		if b & 0x80 == 0 {
			return value, true
		}
		if shift > 28 {
			return 0, false // absurdly large; refuse instead of overflowing
		}
	}
}

// hpack_decode_string reads a string literal: H bit + 7-bit-prefix length + bytes.
hpack_decode_string :: proc(data: []byte, pos: ^int, allocator := context.allocator) -> (s: string, ok: bool) {
	if pos^ >= len(data) {
		return "", false
	}
	is_huffman := data[pos^] & 0x80 != 0
	length := hpack_decode_integer(data, pos, 7) or_return
	if length > len(data) - pos^ {
		return "", false
	}
	raw := data[pos^:][:length]
	pos^ += length

	if is_huffman {
		return huffman_decode(raw, allocator)
	}
	return strings.clone(string(raw), allocator), true
}

// hpack_decode_block decodes a whole header block and appends the headers to
// `out`. Strings in `out` are allocated with `allocator`.
hpack_decode_block :: proc(d: ^Hpack_Decoder, block: []byte, out: ^[dynamic]Header, allocator := context.allocator) -> bool {
	pos := 0
	for pos < len(block) {
		b := block[pos]

		if b & 0x80 != 0 {
			// 1xxxxxxx: Indexed Header Field
			index := hpack_decode_integer(block, &pos, 7) or_return
			h := hpack_lookup(d, index) or_return
			append(out, Header{strings.clone(h.name, allocator), strings.clone(h.value, allocator)})

		} else if b & 0xC0 == 0x40 {
			// 01xxxxxx: Literal with incremental indexing (6-bit index prefix)
			name, value := hpack_decode_literal(d, block, &pos, 6, allocator) or_return
			hpack_table_add(d, name, value)
			append(out, Header{name, value})

		} else if b & 0xE0 == 0x20 {
			// 001xxxxx: Dynamic Table Size Update (5-bit prefix)
			new_size := hpack_decode_integer(block, &pos, 5) or_return
			if new_size > HPACK_DEFAULT_TABLE_SIZE {
				return false // can't exceed what we allowed in SETTINGS
			}
			d.max_size = new_size
			for d.size > d.max_size {
				hpack_evict_oldest(d)
			}

		} else {
			// 0000xxxx: Literal without indexing
			// 0001xxxx: Literal never indexed
			// Both: 4-bit index prefix, and for us they are the same thing.
			name, value := hpack_decode_literal(d, block, &pos, 4, allocator) or_return
			append(out, Header{name, value})
		}
	}
	return true
}

// A literal's name is either an index (> 0) or, if the index is 0, a string.
// The value is always a string.
@(private)
hpack_decode_literal :: proc(d: ^Hpack_Decoder, data: []byte, pos: ^int, prefix_bits: uint, allocator: mem.Allocator) -> (name: string, value: string, ok: bool) {
	name_index := hpack_decode_integer(data, pos, prefix_bits) or_return
	if name_index == 0 {
		name = hpack_decode_string(data, pos, allocator) or_return
	} else {
		h := hpack_lookup(d, name_index) or_return
		name = strings.clone(h.name, allocator)
	}
	value, ok = hpack_decode_string(data, pos, allocator)
	if !ok {
		delete(name, allocator)
	}
	return
}

// huffman_decode turns Huffman-coded bytes back into a string, using the
// table in hpack_huffman_table.odin.
//
// We keep a small bit accumulator. After each input byte we repeatedly look
// for the symbol whose code matches the next bits; since the code is
// prefix-free at most one can match. This is the slow-but-obvious way (a scan
// of 256 entries per symbol). Real implementations use lookup tables.
huffman_decode :: proc(src: []byte, allocator := context.allocator) -> (s: string, ok: bool) {
	out := make([dynamic]byte, 0, len(src) * 8 / 5 + 1, allocator)
	bits: u64 = 0 // the pending bits, right-aligned
	bit_count: uint = 0 // how many bits of `bits` are pending

	for b in src {
		bits = bits << 8 | u64(b)
		bit_count += 8

		// Emit as many symbols as the pending bits allow (shortest code is 5 bits).
		for bit_count >= 5 {
			matched := false
			for symbol in 0 ..< 256 {
				code_length := uint(HUFFMAN_LENS[symbol])
				if code_length > bit_count {
					continue
				}
				// The top `code_length` pending bits:
				top := (bits >> (bit_count - code_length)) & ((u64(1) << code_length) - 1)
				if u32(top) == HUFFMAN_CODES[symbol] {
					append(&out, u8(symbol))
					bit_count -= code_length
					bits &= (u64(1) << bit_count) - 1 // drop the consumed bits
					matched = true
					break
				}
			}
			if !matched {
				if bit_count >= uint(HUFFMAN_EOS_LEN) {
					// 30+ bits that match nothing: invalid, or EOS inside the
					// string (which the RFC says is an error).
					delete(out)
					return "", false
				}
				break // need more input bits to complete the code
			}
		}
	}

	// What's left must be PADDING: fewer than 8 bits, all set to 1
	// (= the beginning of the EOS code).
	if bit_count >= 8 || bits != (u64(1) << bit_count) - 1 {
		delete(out)
		return "", false
	}
	return string(out[:]), true
}

// -----------------------------------------------------------------------------
// Encoder side (used for our responses, and by the tests' HTTP/2 client)
// -----------------------------------------------------------------------------

// hpack_append_integer is the inverse of hpack_decode_integer. `flags` are the
// instruction bits that go above the prefix in the first byte.
hpack_append_integer :: proc(buf: ^[dynamic]byte, flags: u8, prefix_bits: uint, value: int) {
	max_prefix := (1 << prefix_bits) - 1
	if value < max_prefix {
		append(buf, flags | u8(value))
		return
	}
	append(buf, flags | u8(max_prefix))
	rest := value - max_prefix
	for rest >= 0x80 {
		append(buf, u8(rest & 0x7F) | 0x80)
		rest >>= 7
	}
	append(buf, u8(rest))
}

// hpack_append_string writes a string literal WITHOUT Huffman (H bit = 0).
hpack_append_string :: proc(buf: ^[dynamic]byte, s: string) {
	hpack_append_integer(buf, 0x00, 7, len(s))
	append(buf, s)
}

// hpack_append_indexed: "header #index from the table" (1xxxxxxx).
hpack_append_indexed :: proc(buf: ^[dynamic]byte, index: int) {
	hpack_append_integer(buf, 0x80, 7, index)
}

// hpack_append_literal: "Literal without indexing, new name" (0000 0000),
// followed by the name and the value as plain strings.
hpack_append_literal :: proc(buf: ^[dynamic]byte, name, value: string) {
	append(buf, 0x00)
	hpack_append_string(buf, name)
	hpack_append_string(buf, value)
}
