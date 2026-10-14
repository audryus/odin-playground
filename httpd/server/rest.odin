package server

// =============================================================================
// rest.odin - the REST API: a tiny in-memory "notes" CRUD with JSON.
//
// The same notes are exposed in three ways:
//   - REST (this file)          : create/list/get/update/delete
//   - WebSocket (websocket.odin): live events when notes change
//   - gRPC (grpc.odin)          : GetNote
//
// JSON is done with core:encoding/json. Struct fields are mapped to JSON keys
// with field tags, like Go's `json:"..."`.
//
// Concurrency rule: s.notes is shared by all connection threads, so EVERY
// access happens between sync.mutex_lock / sync.mutex_unlock. And we never
// hand out pointers/strings owned by the store after unlocking (another thread
// could delete that note a microsecond later): we copy what we need first.
// =============================================================================

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

Note :: struct {
	id:    i64 `json:"id"`,
	title: string `json:"title"`,
	body:  string `json:"body"`,
}

// What a client sends on POST/PUT. No id: the server decides it.
Note_Input :: struct {
	title: string `json:"title"`,
	body:  string `json:"body"`,
}

Error_Body :: struct {
	error: string `json:"error"`,
}

Health_Body :: struct {
	status: string `json:"status"`,
}

// -----------------------------------------------------------------------------
// Response helpers
// -----------------------------------------------------------------------------

// write_json marshals `value` into the response body.
write_json :: proc(resp: ^Response, status: int, value: any) {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil {
		resp.status = 500
		append(&resp.headers, Header{"Content-Type", "text/plain"})
		append(&resp.body, "failed to encode JSON")
		return
	}
	resp.status = status
	append(&resp.headers, Header{"Content-Type", "application/json"})
	append(&resp.body, ..data)
}

write_json_error :: proc(resp: ^Response, status: int, message: string) {
	write_json(resp, status, Error_Body{error = message})
}

// -----------------------------------------------------------------------------
// Store helpers. "_locked" means: the caller MUST hold s.notes_mutex.
// -----------------------------------------------------------------------------

find_note_index_locked :: proc(s: ^Server, id: i64) -> int {
	// Linear search. Fine for a POC; a map[i64]Note would be the next step.
	for note, i in s.notes {
		if note.id == id {
			return i
		}
	}
	return -1
}

// notes_get_copy returns a copy of a note whose strings are cloned with
// `allocator`, so the caller can use it after the lock is released.
// Used by the REST handlers AND by the gRPC handler.
notes_get_copy :: proc(s: ^Server, id: i64, allocator := context.temp_allocator) -> (note: Note, found: bool) {
	sync.mutex_lock(&s.notes_mutex)
	defer sync.mutex_unlock(&s.notes_mutex)

	index := find_note_index_locked(s, id)
	if index < 0 {
		return {}, false
	}
	stored := s.notes[index]
	note = Note {
		id    = stored.id,
		title = strings.clone(stored.title, allocator),
		body  = strings.clone(stored.body, allocator),
	}
	return note, true
}

// -----------------------------------------------------------------------------
// Handlers. Signature: (server, request, response [, id]).
// They never touch the socket; they only fill `resp`.
// -----------------------------------------------------------------------------

// GET /health
handle_health :: proc(s: ^Server, req: ^Request, resp: ^Response) {
	write_json(resp, 200, Health_Body{status = "ok"})
}

// GET /notes -> 200 [{"id":1,...}, ...]
handle_list_notes :: proc(s: ^Server, req: ^Request, resp: ^Response) {
	sync.mutex_lock(&s.notes_mutex)
	// Marshal while holding the lock: json.marshal reads the stored strings.
	// The resulting bytes are a copy, so they're safe after unlock.
	data, err := json.marshal(s.notes[:], allocator = context.temp_allocator)
	sync.mutex_unlock(&s.notes_mutex)

	if err != nil {
		write_json_error(resp, 500, "failed to encode JSON")
		return
	}
	resp.status = 200
	append(&resp.headers, Header{"Content-Type", "application/json"})
	append(&resp.body, ..data)
}

// POST /notes {"title":"...","body":"..."} -> 201 + Location + the new note
handle_create_note :: proc(s: ^Server, req: ^Request, resp: ^Response) {
	input: Note_Input
	if err := json.unmarshal(req.body, &input, allocator = context.temp_allocator); err != nil {
		write_json_error(resp, 400, "invalid JSON body")
		return
	}
	if len(strings.trim_space(input.title)) == 0 {
		write_json_error(resp, 400, "title is required")
		return
	}

	sync.mutex_lock(&s.notes_mutex)
	s.next_note_id += 1
	id := s.next_note_id
	// The store outlives this request, so its strings must NOT live in the temp
	// allocator: clone them into the server's allocator.
	append(&s.notes, Note{
		id    = id,
		title = strings.clone(input.title, s.allocator),
		body  = strings.clone(input.body, s.allocator),
	})
	sync.mutex_unlock(&s.notes_mutex)

	// For the response we use `input`'s strings (temp memory, owned by us),
	// not the stored ones.
	created := Note{id = id, title = input.title, body = input.body}

	append(&resp.headers, Header{"Location", fmt.tprintf("/notes/%d", id)})
	write_json(resp, 201, created)

	// Tell every connected WebSocket client.
	websocket_broadcast_note_event(s, "note_created", created)
}

// GET /notes/{id} -> 200 note | 404
handle_get_note :: proc(s: ^Server, req: ^Request, resp: ^Response, id: i64) {
	note, found := notes_get_copy(s, id)
	if !found {
		write_json_error(resp, 404, "note not found")
		return
	}
	write_json(resp, 200, note)
}

// PUT /notes/{id} {"title":"...","body":"..."} -> 200 note | 404
handle_update_note :: proc(s: ^Server, req: ^Request, resp: ^Response, id: i64) {
	input: Note_Input
	if err := json.unmarshal(req.body, &input, allocator = context.temp_allocator); err != nil {
		write_json_error(resp, 400, "invalid JSON body")
		return
	}
	if len(strings.trim_space(input.title)) == 0 {
		write_json_error(resp, 400, "title is required")
		return
	}

	sync.mutex_lock(&s.notes_mutex)
	index := find_note_index_locked(s, id)
	if index < 0 {
		sync.mutex_unlock(&s.notes_mutex)
		write_json_error(resp, 404, "note not found")
		return
	}
	stored := &s.notes[index]
	// Free the old strings, store clones of the new ones.
	delete(stored.title, s.allocator)
	delete(stored.body, s.allocator)
	stored.title = strings.clone(input.title, s.allocator)
	stored.body = strings.clone(input.body, s.allocator)
	sync.mutex_unlock(&s.notes_mutex)

	updated := Note{id = id, title = input.title, body = input.body}
	write_json(resp, 200, updated)
	websocket_broadcast_note_event(s, "note_updated", updated)
}

// DELETE /notes/{id} -> 204 (empty body) | 404
handle_delete_note :: proc(s: ^Server, req: ^Request, resp: ^Response, id: i64) {
	sync.mutex_lock(&s.notes_mutex)
	index := find_note_index_locked(s, id)
	if index < 0 {
		sync.mutex_unlock(&s.notes_mutex)
		write_json_error(resp, 404, "note not found")
		return
	}
	delete(s.notes[index].title, s.allocator)
	delete(s.notes[index].body, s.allocator)
	ordered_remove(&s.notes, index) // keep the list sorted by id
	sync.mutex_unlock(&s.notes_mutex)

	resp.status = 204
	websocket_broadcast_note_event(s, "note_deleted", Note{id = id})
}
