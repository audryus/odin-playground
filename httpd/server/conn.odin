package server

// =============================================================================
// conn.odin - a TCP socket plus a receive buffer.
//
// TCP is a byte STREAM, not a message protocol. One recv() can return half an
// HTTP request, or one and a half requests, or a WebSocket frame split in two.
// So every protocol parser in this POC works the same way:
//
//   1. keep the bytes received so far in `buf`,
//   2. "do I have enough bytes to parse the next thing?" -> if not, recv() more,
//   3. parse it and remove those bytes from the front of `buf`.
//
// That's all this file does.
// =============================================================================

import "core:net"
import "core:strings"

Conn :: struct {
	socket: net.TCP_Socket,
	buf:    [dynamic]byte, // received but not yet consumed bytes
}

RECV_CHUNK_SIZE :: 4096

// conn_fill does ONE recv() and appends whatever arrived to c.buf.
// Returns false if the peer closed the connection (recv returns 0) or on error.
conn_fill :: proc(c: ^Conn) -> bool {
	chunk: [RECV_CHUNK_SIZE]byte
	n, err := net.recv_tcp(c.socket, chunk[:])
	if err != nil || n == 0 {
		return false
	}
	append(&c.buf, ..chunk[:n])
	return true
}

// conn_ensure keeps receiving until at least n bytes are buffered.
conn_ensure :: proc(c: ^Conn, n: int) -> bool {
	for len(c.buf) < n {
		if !conn_fill(c) {
			return false
		}
	}
	return true
}

// conn_take removes the first n bytes from the buffer and returns them as a
// new slice allocated with `allocator` (the caller owns it).
conn_take :: proc(c: ^Conn, n: int, allocator := context.allocator) -> (data: []byte, ok: bool) {
	if !conn_ensure(c, n) {
		return nil, false
	}
	data = make([]byte, n, allocator)
	copy(data, c.buf[:n])
	remove_range(&c.buf, 0, n)
	return data, true
}

// conn_find keeps receiving until `delimiter` shows up in the buffer, and
// returns how many bytes there are up to and INCLUDING the delimiter.
// Gives up (too_large = true) if the buffer grows beyond max_bytes without
// finding it - otherwise a client could make us buffer forever.
conn_find :: proc(c: ^Conn, delimiter: string, max_bytes: int) -> (length: int, ok: bool, too_large: bool) {
	for {
		index := strings.index(string(c.buf[:]), delimiter)
		if index >= 0 {
			return index + len(delimiter), true, false
		}
		if len(c.buf) > max_bytes {
			return 0, false, true
		}
		if !conn_fill(c) {
			return 0, false, false
		}
	}
}

// conn_send writes all bytes to the socket (core:net loops over partial
// writes for us on Linux).
conn_send :: proc(c: ^Conn, data: []byte) -> bool {
	_, err := net.send_tcp(c.socket, data)
	return err == nil
}
