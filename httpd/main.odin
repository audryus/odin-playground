package main

// =============================================================================
// httpd - a REST + WebSocket + gRPC server written from scratch in Odin.
//
// Usage:
//     odin run . -- [port]          (default port 8080)
//
// All the interesting code is in the `server` package (./server). This file
// only parses the port, starts the server and waits forever.
// =============================================================================

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import "server"

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	defer log.destroy_console_logger(context.logger)

	port := 8080
	if len(os.args) > 1 {
		parsed, ok := strconv.parse_int(os.args[1], 10)
		if !ok || parsed < 0 || parsed > 65535 {
			fmt.eprintfln("invalid port: %s", os.args[1])
			os.exit(1)
		}
		port = parsed
	}

	s: server.Server
	if err := server.server_start(&s, net.Endpoint{address = net.IP4_Any, port = port}); err != nil {
		log.fatalf("could not listen on port %d: %v", port, err)
		os.exit(1)
	}

	address := net.endpoint_to_string(s.endpoint)
	log.infof("listening on %s", address)
	log.infof("  REST       curl http://localhost:%d/notes", s.endpoint.port)
	log.infof("  WebSocket  ws://localhost:%d/ws", s.endpoint.port)
	log.infof("  gRPC       h2c://localhost:%d  notes.v1.NotesService/GetNote", s.endpoint.port)

	// Runs until the process is killed (Ctrl+C).
	server.server_wait(&s)
}
