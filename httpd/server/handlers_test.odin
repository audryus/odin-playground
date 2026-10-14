package server

// =============================================================================
// handlers_test.odin - REST handler tests WITHOUT any network.
//
// The Go equivalent:
//
//     rec := httptest.NewRecorder()
//     req := httptest.NewRequest("GET", "/health", nil)
//     mux.ServeHTTP(rec, req)
//     if rec.Code != 200 { t.Fatal(...) }
//
// Here: test_request() + test_recorder() + route(). Fast, deterministic, and
// it exercises the router + handlers + JSON, everything except the sockets.
// =============================================================================

import "core:encoding/json"
import "core:testing"

@(test)
test_handler_health :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("GET", "/health")
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, string(resp.body[:]), `{"status":"ok"}`)
	content_type, _ := header_get(resp.headers[:], "Content-Type")
	testing.expect_value(t, content_type, "application/json")
}

@(test)
test_handler_list_notes_empty :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("GET", "/notes")
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, string(resp.body[:]), `[]`)
}

@(test)
test_handler_create_then_get_note :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	// POST /notes
	{
		req := test_request("POST", "/notes", `{"title":"groceries","body":"milk, eggs"}`)
		resp := test_recorder()
		route(&s, &req, &resp)

		testing.expect_value(t, resp.status, 201)
		location, _ := header_get(resp.headers[:], "Location")
		testing.expect_value(t, location, "/notes/1")

		// Decode the JSON instead of comparing strings: field order and
		// spacing shouldn't matter to a test.
		created: Note
		err := json.unmarshal(resp.body[:], &created, allocator = context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, created.id, 1)
		testing.expect_value(t, created.title, "groceries")
		testing.expect_value(t, created.body, "milk, eggs")
	}

	// GET /notes/1
	{
		req := test_request("GET", "/notes/1")
		resp := test_recorder()
		route(&s, &req, &resp)

		testing.expect_value(t, resp.status, 200)
		testing.expect_value(t, string(resp.body[:]), `{"id":1,"title":"groceries","body":"milk, eggs"}`)
	}

	// The store really has it.
	testing.expect_value(t, len(s.notes), 1)
}

@(test)
test_handler_create_note_rejects_invalid_json :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("POST", "/notes", `{"title": oops`)
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 400)
	testing.expect_value(t, string(resp.body[:]), `{"error":"invalid JSON body"}`)
	testing.expect_value(t, len(s.notes), 0)
}

@(test)
test_handler_create_note_requires_title :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("POST", "/notes", `{"title":"   ","body":"x"}`)
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 400)
	testing.expect_value(t, string(resp.body[:]), `{"error":"title is required"}`)
}

@(test)
test_handler_get_unknown_note_is_404 :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("GET", "/notes/99")
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 404)
}

@(test)
test_handler_invalid_id_is_400 :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	// A table-driven test, Go style.
	cases := []string{"/notes/abc", "/notes/0", "/notes/-1", "/notes/"}
	for path in cases {
		req := test_request("GET", path)
		resp := test_recorder()
		route(&s, &req, &resp)
		testing.expectf(t, resp.status == 400, "GET %s: expected 400, got %d", path, resp.status)
	}
}

@(test)
test_handler_method_not_allowed :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("PATCH", "/notes")
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 405)
	allow, _ := header_get(resp.headers[:], "Allow")
	testing.expect_value(t, allow, "GET, POST")
}

@(test)
test_handler_update_and_delete :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	steps := []struct {
		method, path, body: string,
		want_status:        int,
		want_body:          string,
	}{
		{"POST", "/notes", `{"title":"a","body":"1"}`, 201, `{"id":1,"title":"a","body":"1"}`},
		{"PUT", "/notes/1", `{"title":"b","body":"2"}`, 200, `{"id":1,"title":"b","body":"2"}`},
		{"GET", "/notes/1", "", 200, `{"id":1,"title":"b","body":"2"}`},
		{"PUT", "/notes/7", `{"title":"b","body":"2"}`, 404, `{"error":"note not found"}`},
		{"DELETE", "/notes/1", "", 204, ""},
		{"DELETE", "/notes/1", "", 404, `{"error":"note not found"}`},
		{"GET", "/notes", "", 200, `[]`},
	}
	for step in steps {
		req := test_request(step.method, step.path, step.body)
		resp := test_recorder()
		route(&s, &req, &resp)
		testing.expectf(t, resp.status == step.want_status, "%s %s: status %d, want %d", step.method, step.path, resp.status, step.want_status)
		testing.expectf(t, string(resp.body[:]) == step.want_body, "%s %s: body %q, want %q", step.method, step.path, string(resp.body[:]), step.want_body)
	}
}

@(test)
test_handler_unknown_path_is_404 :: proc(t: ^testing.T) {
	s: Server
	server_init(&s)
	defer server_destroy(&s)

	req := test_request("GET", "/nope")
	resp := test_recorder()
	route(&s, &req, &resp)

	testing.expect_value(t, resp.status, 404)
}
