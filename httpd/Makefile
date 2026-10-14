# httpd - REST + WebSocket + gRPC server written from scratch in Odin.
#
#   make run          build and run on port 8080 (PORT=9000 make run to change)
#   make build        only build the binary into build/
#   make test         run the Odin tests (package ./server)
#   make test-one T=test_grpc_get_note   run a single test
#   make grpc-call    call GetNote with the real grpc-go client (ID=1)
#   make demo         a few curl calls against a running server
#   make clean        delete build/

ODIN     := odin
OUT_DIR  := build
PORT     ?= 8080
ID       ?= 1

.PHONY: all build run test test-one grpc-call demo clean

all: build

build:
	mkdir -p $(OUT_DIR)
	$(ODIN) build . -out:$(OUT_DIR)/httpd -vet -debug

run: build
	./$(OUT_DIR)/httpd $(PORT)

# -vet catches unused variables/imports, like `go vet`.
test:
	mkdir -p $(OUT_DIR)
	$(ODIN) test server -vet -out:$(OUT_DIR)/server_tests

# Odin's equivalent of `go test -run TestName`.
test-one:
	mkdir -p $(OUT_DIR)
	$(ODIN) test server -out:$(OUT_DIR)/server_tests -define:ODIN_TEST_NAMES=server.$(T)

# Independent client: grpc-go (needs Go; downloads its modules on first run).
grpc-call:
	cd tools/grpc_client && go run . -addr localhost:$(PORT) -id $(ID)

demo:
	curl -s -X POST localhost:$(PORT)/notes -d '{"title":"hello","body":"from curl"}'; echo
	curl -s localhost:$(PORT)/notes; echo
	@echo "--- gRPC via curl (GetNote id=1: 5-byte gRPC prefix + protobuf 08 01)"
	printf '\x00\x00\x00\x00\x02\x08\x01' | curl -s --http2-prior-knowledge \
		-H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
		localhost:$(PORT)/notes.v1.NotesService/GetNote | od -A d -t x1 -c

clean:
	rm -rf $(OUT_DIR)
