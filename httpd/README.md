# httpd — REST + WebSocket + gRPC from scratch in Odin

A learning POC: one TCP server that speaks three protocols, written by hand
on top of `core:net`. Odin's core library has sockets, JSON, SHA-1 and
base64, but no HTTP, WebSocket, HTTP/2 or protobuf. Every one of those is
implemented here in plain code, with no abstraction layers, so you can read
what goes over the wire.

```
                         TCP :8080
                             |
                    connection_thread           (server.odin)
              peeks at the first 4 bytes
               /                         \
        "PRI " (HTTP/2)              anything else (HTTP/1.1)
             |                              |
         h2_serve                       http1_serve          (http1.odin)
       (http2.odin)                    /          \
             |                    route()     Upgrade: websocket
         HPACK decode            (REST)            |
       (hpack.odin)            (rest.odin)    websocket_serve
             |                      |         (websocket.odin)
     grpc_handle_stream             +---- broadcast ---->|
       (grpc.odin)                  |   note events      |
             |                      |                    |
      protobuf decode/encode        +------ notes (in memory, mutex) 
       (protobuf.odin)  ------------+
```

All three APIs share the same in-memory notes:

| Protocol  | Endpoint                                   | What it does                         |
|-----------|--------------------------------------------|--------------------------------------|
| REST      | `GET /health`                              | `{"status":"ok"}`                    |
| REST      | `GET /notes`, `POST /notes`                | list / create (`{"title","body"}`)   |
| REST      | `GET/PUT/DELETE /notes/{id}`               | read / replace / delete              |
| WebSocket | `GET /ws`                                  | echoes messages and pushes `note_created` / `note_updated` / `note_deleted` events |
| gRPC      | `notes.v1.NotesService/GetNote` (h2c)      | see [`proto/notes.proto`](proto/notes.proto) |

## Running

```sh
make run                 # builds and listens on :8080 (PORT=9000 make run)
make demo                # in another terminal: curl REST + a raw gRPC call
make grpc-call ID=1      # real grpc-go client (tools/grpc_client)
```

By hand:

```sh
curl -i -X POST localhost:8080/notes -d '{"title":"hello","body":"world"}'
curl -s localhost:8080/notes
curl -s -X PUT localhost:8080/notes/1 -d '{"title":"hi","body":"edited"}'
curl -i -X DELETE localhost:8080/notes/1
```

WebSocket, from a browser console (or Node ≥ 22, which ships a `WebSocket` global):

```js
const ws = new WebSocket("ws://localhost:8080/ws");
ws.onmessage = (e) => console.log(e.data);
ws.onopen = () => ws.send("hi");   // -> "hi" comes back
// now POST a note with curl and watch the event arrive
```

gRPC with curl. The body is a 5-byte gRPC prefix (compressed flag + big-endian
length) followed by the protobuf bytes `08 01` (field 1 = 1):

```sh
printf '\x00\x00\x00\x00\x02\x08\x01' | curl -v --http2-prior-knowledge \
  -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
  localhost:8080/notes.v1.NotesService/GetNote | xxd
# look for "< grpc-status: 0" in the verbose output: that's the trailer
```

If you have `grpcurl`: `grpcurl -plaintext -proto proto/notes.proto -d '{"id":1}' localhost:8080 notes.v1.NotesService/GetNote`.

## Reading order

Each file starts with a comment that explains its protocol, with diagrams.
To learn the code, read the files in this order:

1. `server/conn.odin`: TCP is a stream, so every parser buffers bytes
2. `server/server.odin`: listen/accept, one thread per connection, protocol sniffing, shutdown
3. `server/http1.odin`: request parsing, response writing, keep-alive, the router
4. `server/rest.odin`: JSON handlers and the mutex-protected store
5. `server/websocket.odin`: handshake (SHA-1 + base64), frame format, masking, fragmentation
6. `server/protobuf.odin`: varints, keys, wire types
7. `server/hpack.odin`: HTTP/2 header compression: static/dynamic tables, Huffman
8. `server/http2.odin`: frames, SETTINGS/PING/HEADERS/CONTINUATION/DATA, flow control
9. `server/grpc.odin`: gRPC on HTTP/2: length-prefixed messages and trailers

## Tests (and how they map to Go's `httptest`)

```sh
make test                              # odin test server -vet
make test-one T=test_grpc_get_note     # like go test -run
```

| Go                                   | Here                                                         |
|--------------------------------------|--------------------------------------------------------------|
| `httptest.NewRecorder()` + `ServeHTTP` | `test_request()` + `test_recorder()` + `route()`, with no sockets (`handlers_test.odin`) |
| `httptest.NewServer()`               | `test_server_start()`: a real server on `127.0.0.1:0` (`helpers_test.odin`) |
| `http.Client`                        | `test_http_do()`: a ~40-line raw HTTP/1.1 client                     |
| `gorilla/websocket` dialer           | `test_ws_connect()` / `test_ws_send_frame()` / `test_ws_read_frame()` |
| `grpc.Dial` + stub                   | `test_h2_connect()` / `test_grpc_call()`: a tiny HTTP/2 client       |
| table-driven tests                   | slices of anonymous structs, `for c in cases`                |
| `-race`                              | none, but every test has a **tracking allocator** and fails on leaks |

Test files:

- `handlers_test.odin`: REST handlers, no network
- `http_test.odin`: real sockets: CRUD, keep-alive, `Connection: close`, a request sent one byte at a time, malformed input, 413/501
- `websocket_test.odin`: RFC accept-key example, echo, 16-bit lengths, fragmentation + ping in between, close handshake, unmasked frame → 1002, bad UTF-8 → 1007, REST→WS broadcast
- `grpc_test.odin`: protobuf varints and unknown fields, HPACK checked against the worked examples in RFC 7541 Appendix C (integers, Huffman, dynamic table), and gRPC end-to-end: OK, NOT_FOUND, UNIMPLEMENTED, several streams on one connection

The tests' HTTP/2 client reuses the server's own frame and HPACK code. To check
against an independent implementation, `tools/grpc_client` calls the server
with **grpc-go**, which Huffman-encodes headers and uses the HPACK dynamic table.

## Deliberate limitations

This is a POC for reading, not for production:

- One OS thread per connection with blocking I/O (Odin's `core:nbio` would be the next step).
- HTTP/1.1: no chunked request bodies, no `Expect: 100-continue`, no TLS.
- HTTP/2: no send-side flow control. Responses are assumed to fit in the client's window, which holds for small unary calls. No priorities, no push, no stream limits.
- gRPC: unary only, no compression, `grpc-message` is not percent-encoded.
- Huffman decoding is the slow, obvious version: a scan of 256 entries for each decoded symbol.
- Notes live in memory in a `[dynamic]Note` with linear search.
