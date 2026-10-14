package server

// =============================================================================
// server.odin - the TCP server: listen, accept, one thread per connection.
//
// Big picture of this POC:
//
//     TCP accept()
//         |
//         v
//     connection_thread  -- peeks at the first bytes of the connection
//         |
//         +-- "PRI * HTTP/2.0..."  -> h2_serve()     (http2.odin)  -> gRPC (grpc.odin)
//         |
//         +-- anything else        -> http1_serve()  (http1.odin)  -> REST (rest.odin)
//                                                                  -> WebSocket upgrade (websocket.odin)
//
// Everything is built directly on top of `core:net` (plain BSD sockets).
// There is no HTTP library in Odin's core collection, so we parse and write
// the protocols by hand. That is the whole point of the POC: see every byte.
//
// Threading model: the simplest one that works. One OS thread per connection,
// blocking reads and writes. It doesn't scale to 10k connections, but it is
// very easy to follow (the same model as a "goroutine per connection" in Go's
// net/http, minus the cheap goroutines).
// =============================================================================

import "base:runtime"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

// Server holds ALL the state of one running server.
//
// There are no global variables on purpose: tests start many servers at the
// same time (Odin's test runner runs tests in parallel), and each one must have
// its own notes, its own listener, etc.
Server :: struct {
	// Allocator for long-lived data (notes, client lists). Captured from the
	// caller of server_start. In tests this is the test's tracking allocator,
	// so leaks inside the server make the test fail.
	allocator: mem.Allocator,

	listener:      net.TCP_Socket,
	endpoint:      net.Endpoint, // the REAL bound address (matters when port = 0)
	accept_thread: ^thread.Thread,

	// Set to true by server_stop. Read by the accept loop.
	stopping: bool,

	// Every open client socket, so server_stop can kick them out of a blocking
	// recv(). Protected by connections_mutex.
	connections_mutex:  sync.Mutex,
	connections:        [dynamic]net.TCP_Socket,
	active_connections: int, // atomic counter, reaches 0 when every thread is done

	// The "database": an in-memory list of notes, protected by notes_mutex
	// because every connection runs on its own thread.
	notes_mutex:  sync.Mutex,
	notes:        [dynamic]Note,
	next_note_id: i64,

	// Connected WebSocket clients, used to broadcast note events.
	ws_mutex:   sync.Mutex,
	ws_clients: [dynamic]^Ws_Client,
}

// server_init prepares the data of a Server WITHOUT opening any socket.
// Handler tests use only this (+ server_destroy): they call the router
// directly, no network involved.
server_init :: proc(s: ^Server, allocator := context.allocator) {
	s.allocator = allocator
	s.notes = make([dynamic]Note, s.allocator)
	s.ws_clients = make([dynamic]^Ws_Client, s.allocator)
	s.connections = make([dynamic]net.TCP_Socket, s.allocator)
}

// server_destroy frees the data allocated by server_init and by the handlers.
server_destroy :: proc(s: ^Server) {
	// Note strings were cloned with s.allocator, so we free them with it too.
	for note in s.notes {
		delete(note.title, s.allocator)
		delete(note.body, s.allocator)
	}
	delete(s.notes)
	delete(s.ws_clients)
	delete(s.connections)
}

// server_start opens the listening socket and starts the accept thread.
// It returns immediately; the server runs in the background.
//
// Pass port 0 to let the OS pick a free port (that's what tests do, exactly
// like Go's httptest.NewServer). The chosen port is then in s.endpoint.
server_start :: proc(s: ^Server, endpoint: net.Endpoint) -> (err: net.Network_Error) {
	server_init(s)

	// socket() + setsockopt(SO_REUSEADDR) + bind() + listen(), in one call.
	listener, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		server_destroy(s)
		return listen_err
	}
	s.listener = listener

	// Ask the OS which address/port we actually got.
	bound, info_err := net.bound_endpoint(listener)
	if info_err != nil {
		net.close(listener)
		server_destroy(s)
		return info_err
	}
	s.endpoint = bound

	// The accept thread inherits our context (allocator + logger).
	s.accept_thread = thread.create_and_start_with_poly_data(s, accept_loop, init_context = context)
	return nil
}

// server_wait blocks until the accept thread ends (i.e. forever, for main).
server_wait :: proc(s: ^Server) {
	thread.join(s.accept_thread)
}

// server_stop shuts everything down and frees all memory.
// After it returns no thread of this server is touching `s` anymore.
server_stop :: proc(s: ^Server) {
	sync.atomic_store(&s.stopping, true)

	// shutdown() on a listening socket makes the blocked accept() return with
	// an error on Linux. close() alone would NOT wake it up.
	net.shutdown(s.listener, .Both)
	thread.join(s.accept_thread)
	thread.destroy(s.accept_thread)
	net.close(s.listener)

	// Same trick for every client connection: shutdown() makes their blocking
	// recv() return 0, so their threads finish.
	sync.mutex_lock(&s.connections_mutex)
	for socket in s.connections {
		net.shutdown(socket, .Both)
	}
	sync.mutex_unlock(&s.connections_mutex)

	// Wait for all connection threads to finish (they decrement the counter as
	// the very last thing they do).
	for sync.atomic_load(&s.active_connections) > 0 {
		time.sleep(1 * time.Millisecond)
	}

	server_destroy(s)
}

// accept_loop runs on its own thread: accept a client, spawn a thread, repeat.
@(private)
accept_loop :: proc(s: ^Server) {
	for {
		client, source, err := net.accept_tcp(s.listener)
		if sync.atomic_load(&s.stopping) {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			log.warnf("accept failed: %v", err)
			continue
		}
		log.debugf("new connection from %s", net.endpoint_to_string(source, context.temp_allocator))
		free_all(context.temp_allocator)

		// Register BEFORE starting the thread, so server_stop always sees it.
		sync.mutex_lock(&s.connections_mutex)
		append(&s.connections, client)
		sync.mutex_unlock(&s.connections_mutex)
		sync.atomic_add(&s.active_connections, 1)

		// The connection thread sees the same context as us (server allocator
		// and logger). But the ^Thread struct itself is allocated from the plain
		// heap: with self_cleanup the thread frees that struct AFTER our proc
		// returned, i.e. possibly after server_stop returned and a test already
		// checked its tracking allocator for leaks.
		thread_context := context
		context.allocator = runtime.heap_allocator()
		thread.create_and_start_with_poly_data2(
			s,
			client,
			connection_thread,
			init_context = thread_context,
			self_cleanup = true,
		)
		context.allocator = thread_context.allocator
	}
}

// connection_thread owns one client connection from start to end.
@(private)
connection_thread :: proc(s: ^Server, socket: net.TCP_Socket) {
	c := Conn{socket = socket}

	// Protocol detection. An HTTP/2 client that talks plain text ("h2c with
	// prior knowledge", which is what gRPC clients do without TLS) starts the
	// connection with the magic string "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".
	// An HTTP/1.1 client starts with a method, like "GET " or "POST ".
	// "PRI" is not a method we serve, so 4 bytes are enough to decide.
	if conn_ensure(&c, 4) {
		if string(c.buf[:4]) == "PRI " {
			h2_serve(s, &c)
		} else {
			http1_serve(s, &c)
		}
	}

	// Cleanup, in a very deliberate order:
	// 1. forget the socket (so server_stop won't shutdown a reused fd number),
	// 2. close it,
	// 3. free our buffer,
	// 4. decrement the counter LAST: after that, server_stop may free `s`.
	sync.mutex_lock(&s.connections_mutex)
	for socket_in_list, i in s.connections {
		if socket_in_list == socket {
			unordered_remove(&s.connections, i)
			break
		}
	}
	sync.mutex_unlock(&s.connections_mutex)
	net.close(socket)
	delete(c.buf)
	sync.atomic_sub(&s.active_connections, 1)
}
