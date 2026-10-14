// grpc_client calls notes.v1.NotesService/GetNote on the Odin server using
// the official grpc-go library. It exists to prove that the hand-written
// HTTP/2 + HPACK + gRPC code in ../../server interoperates with a real client
// (grpc-go Huffman-encodes headers and uses the HPACK dynamic table).
//
// To avoid needing protoc-gen-go, the protobuf messages are encoded/decoded
// by hand with the low-level protowire package and sent through a "raw bytes"
// codec - the same idea as server/protobuf.odin, in Go.
//
// Usage:
//
//	go run . -addr localhost:8080 -id 1 -n 3
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
)

// rawCodec passes []byte through untouched: we do the protobuf encoding ourselves.
type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error)      { return *(v.(*[]byte)), nil }
func (rawCodec) Unmarshal(data []byte, v any) error { *(v.(*[]byte)) = append([]byte(nil), data...); return nil }
func (rawCodec) Name() string                       { return "proto" } // keeps content-type application/grpc+proto

var _ encoding.Codec = rawCodec{}

func main() {
	addr := flag.String("addr", "localhost:8080", "server address")
	id := flag.Int64("id", 1, "note id to fetch")
	n := flag.Int("n", 1, "how many calls to make on the same connection")
	flag.Parse()

	conn, err := grpc.NewClient(*addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()), // h2c, no TLS
		grpc.WithDefaultCallOptions(grpc.ForceCodec(rawCodec{})),
	)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	// GetNoteRequest{id} = field 1, varint
	request := protowire.AppendTag(nil, 1, protowire.VarintType)
	request = protowire.AppendVarint(request, uint64(*id))

	exitCode := 0
	for i := 0; i < *n; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		var reply []byte
		err := conn.Invoke(ctx, "/notes.v1.NotesService/GetNote", &request, &reply)
		cancel()
		if err != nil {
			st := status.Convert(err)
			fmt.Printf("call %d: error code=%s message=%q\n", i+1, st.Code(), st.Message())
			exitCode = 1
			continue
		}
		fmt.Printf("call %d: %s\n", i+1, decodeNote(reply))
	}
	os.Exit(exitCode)
}

// decodeNote parses Note{id=1, title=2, body=3} with protowire.
func decodeNote(b []byte) string {
	var noteID int64
	var title, body string
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return "invalid protobuf"
		}
		b = b[n:]
		switch {
		case num == 1 && typ == protowire.VarintType:
			v, m := protowire.ConsumeVarint(b)
			noteID, n = int64(v), m
		case num == 2 && typ == protowire.BytesType:
			v, m := protowire.ConsumeString(b)
			title, n = v, m
		case num == 3 && typ == protowire.BytesType:
			v, m := protowire.ConsumeString(b)
			body, n = v, m
		default:
			n = protowire.ConsumeFieldValue(num, typ, b)
		}
		if n < 0 {
			return "invalid protobuf"
		}
		b = b[n:]
	}
	return fmt.Sprintf("Note{id: %d, title: %q, body: %q}", noteID, title, body)
}
