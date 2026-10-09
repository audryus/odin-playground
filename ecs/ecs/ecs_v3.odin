package main

import "core:fmt"
import "core:mem"

// ============================================================
// ECS híbrido: archetype (table) + sparse-set — v3
//
// Storage por componente:
//   .Table  (padrão) — SoA dentro de archetypes. Iteração
//            sequencial perfeita; add/remove caro (migração).
//            Use para: Transform, Health, Stats... coisas que
//            a entidade carrega a vida inteira.
//   .Sparse — sparse-set por componente. Add/remove O(1) sem
//            migração de archetype; iteração varre só o array
//            denso (só quem TEM o componente). Use para:
//            Attack_Intent, Bleeding, Stunned... coisas que
//            entram e saem centenas de vezes por frame.
//
// Queries híbridas: se houver componentes sparse, o MENOR
// sparse set dirige a iteração; cada entidade é validada
// contra a máscara do archetype (O(1)) e os demais sets (O(1)).
//
// Regra de ouro continua: mudanças estruturais dentro de
// queries SEMPRE via Commands (cmd_set/cmd_remove/cmd_destroy).
//
// IMPORTANTE: registre componentes .Sparse com register()
// ANTES do primeiro uso — o registro automático assume .Table.
// ============================================================

Entity :: distinct u32
Component :: distinct u32

ENTITY_NIL :: Entity(max(u32))

MAX_COMPONENTS :: 256
MASK_WORDS :: MAX_COMPONENTS / 64
Mask :: [MASK_WORDS]u64

// ------------------------------------------------------------------
// Mask
// ------------------------------------------------------------------

mask_set :: proc(m: ^Mask, c: Component) {
	m[int(c) / 64] |= u64(1) << uint(int(c) % 64)
}

mask_unset :: proc(m: ^Mask, c: Component) {
	m[int(c) / 64] &~= u64(1) << uint(int(c) % 64)
}

mask_has :: proc(m: Mask, c: Component) -> bool {
	return (m[int(c) / 64] & (u64(1) << uint(int(c) % 64))) != 0
}

mask_contains :: proc(m, req: Mask) -> bool {
	for w in 0 ..< MASK_WORDS {
		if (m[w] & req[w]) != req[w] do return false
	}
	return true
}

// ------------------------------------------------------------------
// Column (storage Table, type-erased)
// ------------------------------------------------------------------

Column :: struct {
	comp:      Component,
	elem_size: int,
	data:      [dynamic]byte,
}

column_ptr :: proc(col: ^Column, row: int) -> rawptr {
	return rawptr(&col.data[row * col.elem_size])
}

column_push :: proc(col: ^Column, src: rawptr) {
	old_len := len(col.data)
	resize(&col.data, old_len + col.elem_size)
	dst := rawptr(&col.data[old_len])
	if src != nil {
		mem.copy(dst, src, col.elem_size)
	} else {
		mem.zero(dst, col.elem_size)
	}
}

column_swap_pop :: proc(col: ^Column, row: int) {
	n := len(col.data) / col.elem_size
	last := n - 1
	if row != last {
		mem.copy(
			rawptr(&col.data[row * col.elem_size]),
			rawptr(&col.data[last * col.elem_size]),
			col.elem_size,
		)
	}
	resize(&col.data, last * col.elem_size)
}

// ------------------------------------------------------------------
// Sparse_Set (storage Sparse)
//
//   sparse[entity_id] -> índice no array denso (-1 = não tem)
//   entities/data     -> densos, contíguos, só quem tem o comp.
//
// Insert/remove O(1) (swap-and-pop no denso). Nenhuma migração
// de archetype acontece — é por isso que componentes voláteis
// ficam baratos.
// ------------------------------------------------------------------

Sparse_Set :: struct {
	elem_size: int,
	sparse:    [dynamic]i32,
	entities:  [dynamic]Entity,
	data:      [dynamic]byte,
}

ss_ensure :: proc(ss: ^Sparse_Set, e: Entity) {
	for int(e) >= len(ss.sparse) do append(&ss.sparse, -1)
}

ss_has :: proc(ss: ^Sparse_Set, e: Entity) -> bool {
	return int(e) < len(ss.sparse) && ss.sparse[int(e)] >= 0
}

ss_ptr :: proc(ss: ^Sparse_Set, e: Entity) -> rawptr {
	return rawptr(&ss.data[int(ss.sparse[int(e)]) * ss.elem_size])
}

ss_insert :: proc(ss: ^Sparse_Set, e: Entity, src: rawptr) {
	ss_ensure(ss, e)
	if di := ss.sparse[int(e)]; di >= 0 {
		// já tem: sobrescreve o valor
		if ss.elem_size > 0 && src != nil {
			mem.copy(rawptr(&ss.data[int(di) * ss.elem_size]), src, ss.elem_size)
		}
		return
	}
	ss.sparse[int(e)] = i32(len(ss.entities))
	append(&ss.entities, e)
	if ss.elem_size > 0 {
		old := len(ss.data)
		resize(&ss.data, old + ss.elem_size)
		if src != nil {
			mem.copy(rawptr(&ss.data[old]), src, ss.elem_size)
		} else {
			mem.zero(rawptr(&ss.data[old]), ss.elem_size)
		}
	}
}

ss_remove :: proc(ss: ^Sparse_Set, e: Entity) {
	if !ss_has(ss, e) do return
	di := int(ss.sparse[int(e)])
	last := len(ss.entities) - 1
	moved := ss.entities[last]
	if di != last {
		ss.entities[di] = moved
		ss.sparse[int(moved)] = i32(di)
		if ss.elem_size > 0 {
			mem.copy(
				rawptr(&ss.data[di * ss.elem_size]),
				rawptr(&ss.data[last * ss.elem_size]),
				ss.elem_size,
			)
		}
	}
	pop(&ss.entities)
	if ss.elem_size > 0 do resize(&ss.data, last * ss.elem_size)
	ss.sparse[int(e)] = -1
}

// ------------------------------------------------------------------
// Archetype / World
// ------------------------------------------------------------------

Archetype :: struct {
	mask:     Mask,
	entities: [dynamic]Entity,
	columns:  [dynamic]Column,
	col_of:   [MAX_COMPONENTS]i16,
}

Storage_Kind :: enum {
	Table,
	Sparse,
}

Component_Info :: struct {
	id:      Component,
	size:    int,
	storage: Storage_Kind,
}

Location :: struct {
	arch: i32,
	row:  i32,
}

World :: struct {
	next_entity: u32,
	infos:       map[typeid]Component_Info,
	sizes:       [MAX_COMPONENTS]int,
	sparse_of:   [MAX_COMPONENTS]i16, // comp -> índice em sparse_sets (-1 = table)
	n_comps:     u32,
	archetypes:  [dynamic]Archetype,
	sparse_sets: [dynamic]Sparse_Set,
	locs:        [dynamic]Location,
}

world_init :: proc(w: ^World) {
	for &x in w.sparse_of do x = -1
	root: Archetype
	for &x in root.col_of do x = -1
	append(&w.archetypes, root)
}

world_destroy :: proc(w: ^World) {
	for &a in w.archetypes {
		delete(a.entities)
		for &c in a.columns do delete(c.data)
		delete(a.columns)
	}
	delete(w.archetypes)
	for &ss in w.sparse_sets {
		delete(ss.sparse)
		delete(ss.entities)
		delete(ss.data)
	}
	delete(w.sparse_sets)
	delete(w.locs)
	delete(w.infos)
}

register :: proc(w: ^World, T: typeid, storage: Storage_Kind) -> Component {
	if info, ok := w.infos[T]; ok {
		assert(info.storage == storage, "componente já registrado com outro storage")
		return info.id
	}
	assert(int(w.n_comps) < MAX_COMPONENTS, "limite de componentes excedido")
	id := Component(w.n_comps)
	w.n_comps += 1
	size := type_info_of(T).size
	w.infos[T] = Component_Info{id = id, size = size, storage = storage}
	w.sizes[int(id)] = size
	if storage == .Sparse {
		w.sparse_of[int(id)] = i16(len(w.sparse_sets))
		ss: Sparse_Set
		ss.elem_size = size
		append(&w.sparse_sets, ss)
	}
	return id
}

// registro automático = .Table
component_id :: proc(w: ^World, T: typeid) -> Component {
	if info, ok := w.infos[T]; ok do return info.id
	return register(w, T, .Table)
}

// ------------------------------------------------------------------
// Entidades
// ------------------------------------------------------------------

ensure_loc :: proc(w: ^World, e: Entity) {
	for int(e) >= len(w.locs) {
		append(&w.locs, Location{arch = -1, row = -1})
	}
}

create_entity :: proc(w: ^World) -> Entity {
	e := Entity(w.next_entity)
	w.next_entity += 1
	ensure_loc(w, e)
	root := &w.archetypes[0]
	w.locs[int(e)] = Location{arch = 0, row = i32(len(root.entities))}
	append(&root.entities, e)
	return e
}

destroy_entity :: proc(w: ^World, e: Entity) {
	loc := w.locs[int(e)]
	if loc.arch < 0 do return
	arch := &w.archetypes[loc.arch]

	last := len(arch.entities) - 1
	moved := arch.entities[last]
	if int(loc.row) != last {
		arch.entities[loc.row] = moved
		w.locs[int(moved)].row = loc.row
	}
	pop(&arch.entities)
	for &col in arch.columns do column_swap_pop(&col, int(loc.row))

	// limpar de todos os sparse sets (status effects morrem junto)
	for &ss in w.sparse_sets do ss_remove(&ss, e)

	w.locs[int(e)] = Location{arch = -1, row = -1}
}

// ------------------------------------------------------------------
// Archetypes: lookup e migração (só componentes .Table)
// ------------------------------------------------------------------

find_or_create_archetype :: proc(w: ^World, mask: Mask) -> int {
	for &a, i in w.archetypes {
		if a.mask == mask do return i
	}
	arch: Archetype
	arch.mask = mask
	for &x in arch.col_of do x = -1
	for c in 0 ..< int(w.n_comps) {
		if mask_has(mask, Component(c)) && w.sizes[c] > 0 && w.sparse_of[c] < 0 {
			arch.col_of[c] = i16(len(arch.columns))
			append(&arch.columns, Column{comp = Component(c), elem_size = w.sizes[c]})
		}
	}
	append(&w.archetypes, arch)
	return len(w.archetypes) - 1
}

move_entity :: proc(w: ^World, e: Entity, new_mask: Mask) {
	dst_idx := find_or_create_archetype(w, new_mask)

	loc := w.locs[int(e)]
	src := &w.archetypes[loc.arch]
	dst := &w.archetypes[dst_idx]

	new_row := len(dst.entities)
	append(&dst.entities, e)
	for &dcol in dst.columns {
		sci := src.col_of[int(dcol.comp)]
		if sci >= 0 {
			column_push(&dcol, column_ptr(&src.columns[sci], int(loc.row)))
		} else {
			column_push(&dcol, nil)
		}
	}

	last := len(src.entities) - 1
	moved := src.entities[last]
	if int(loc.row) != last {
		src.entities[loc.row] = moved
		w.locs[int(moved)].row = loc.row
	}
	pop(&src.entities)
	for &scol in src.columns do column_swap_pop(&scol, int(loc.row))

	w.locs[int(e)] = Location{arch = i32(dst_idx), row = i32(new_row)}
}

// ------------------------------------------------------------------
// set / get / has / remove — roteiam por storage
// ------------------------------------------------------------------

set_raw :: proc(w: ^World, e: Entity, tid: typeid, src: rawptr) {
	c := component_id(w, tid)
	loc := w.locs[int(e)]
	if loc.arch < 0 do return

	// SPARSE: insere/sobrescreve em O(1), sem migração
	if si := w.sparse_of[int(c)]; si >= 0 {
		ss_insert(&w.sparse_sets[si], e, src)
		return
	}

	// TABLE: pode exigir migração de archetype
	arch := &w.archetypes[loc.arch]
	if !mask_has(arch.mask, c) {
		new_mask := arch.mask
		mask_set(&new_mask, c)
		move_entity(w, e, new_mask)
		loc = w.locs[int(e)]
		arch = &w.archetypes[loc.arch]
	}
	ci := arch.col_of[int(c)]
	if ci >= 0 && src != nil {
		mem.copy(column_ptr(&arch.columns[ci], int(loc.row)), src, arch.columns[ci].elem_size)
	}
}

remove_raw :: proc(w: ^World, e: Entity, tid: typeid) {
	c := component_id(w, tid)
	loc := w.locs[int(e)]
	if loc.arch < 0 do return

	if si := w.sparse_of[int(c)]; si >= 0 {
		ss_remove(&w.sparse_sets[si], e)
		return
	}

	arch := &w.archetypes[loc.arch]
	if !mask_has(arch.mask, c) do return
	new_mask := arch.mask
	mask_unset(&new_mask, c)
	move_entity(w, e, new_mask)
}

set :: proc(w: ^World, e: Entity, value: $T) {
	v := value
	when size_of(T) > 0 {
		set_raw(w, e, T, &v)
	} else {
		set_raw(w, e, T, nil)
	}
}

get :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	c := component_id(w, T)
	loc := w.locs[int(e)]
	if loc.arch < 0 do return nil

	if si := w.sparse_of[int(c)]; si >= 0 {
		ss := &w.sparse_sets[si]
		if !ss_has(ss, e) do return nil
		return (^T)(ss_ptr(ss, e))
	}

	arch := &w.archetypes[loc.arch]
	ci := arch.col_of[int(c)]
	if ci < 0 do return nil
	return (^T)(column_ptr(&arch.columns[ci], int(loc.row)))
}

has :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	c := component_id(w, T)
	loc := w.locs[int(e)]
	if loc.arch < 0 do return false
	if si := w.sparse_of[int(c)]; si >= 0 {
		return ss_has(&w.sparse_sets[si], e)
	}
	return mask_has(w.archetypes[loc.arch].mask, c)
}

remove :: proc(w: ^World, e: Entity, $T: typeid) {
	remove_raw(w, e, T)
}

// ------------------------------------------------------------------
// Commands (inalterado: set_raw/remove_raw já roteiam por storage)
// ------------------------------------------------------------------

Command_Kind :: enum {
	Spawn,
	Set,
	Remove,
	Destroy,
}

Command :: struct {
	kind:   Command_Kind,
	entity: Entity,
	tid:    typeid,
	offset: int,
}

Commands :: struct {
	queue: [dynamic]Command,
	data:  [dynamic]byte,
}

commands_destroy :: proc(cb: ^Commands) {
	delete(cb.queue)
	delete(cb.data)
}

cmd_spawn :: proc(w: ^World, cb: ^Commands) -> Entity {
	e := Entity(w.next_entity)
	w.next_entity += 1
	append(&cb.queue, Command{kind = .Spawn, entity = e})
	return e
}

cmd_set :: proc(cb: ^Commands, e: Entity, value: $T) {
	offset := len(cb.data)
	when size_of(T) > 0 {
		resize(&cb.data, offset + size_of(T))
		v := value
		mem.copy(rawptr(&cb.data[offset]), &v, size_of(T))
	}
	append(&cb.queue, Command{kind = .Set, entity = e, tid = T, offset = offset})
}

cmd_remove :: proc(cb: ^Commands, e: Entity, $T: typeid) {
	append(&cb.queue, Command{kind = .Remove, entity = e, tid = T})
}

cmd_destroy :: proc(cb: ^Commands, e: Entity) {
	append(&cb.queue, Command{kind = .Destroy, entity = e})
}

commands_flush :: proc(w: ^World, cb: ^Commands) {
	for cmd in cb.queue {
		switch cmd.kind {
		case .Spawn:
			ensure_loc(w, cmd.entity)
			root := &w.archetypes[0]
			w.locs[int(cmd.entity)] = Location{arch = 0, row = i32(len(root.entities))}
			append(&root.entities, cmd.entity)
		case .Set:
			size := type_info_of(cmd.tid).size
			src: rawptr = nil
			if size > 0 do src = rawptr(&cb.data[cmd.offset])
			set_raw(w, cmd.entity, cmd.tid, src)
		case .Remove:
			remove_raw(w, cmd.entity, cmd.tid)
		case .Destroy:
			destroy_entity(w, cmd.entity)
		}
	}
	clear(&cb.queue)
	clear(&cb.data)
}

// ------------------------------------------------------------------
// Query híbrida
//
// Sem componentes sparse: itera archetypes (sequencial puro).
// Com componentes sparse: o MENOR sparse set dirige; cada
// entidade do denso é validada contra a máscara do archetype
// e os demais sets. Itera só quem tem o componente raro —
// 30 sangrando em 10.000 entidades = 30 iterações.
// ------------------------------------------------------------------

MAX_QUERY_SPARSE :: 8

Query :: struct {
	w:          ^World,
	table_mask: Mask,
	sparse:     [MAX_QUERY_SPARSE]int, // índices em w.sparse_sets
	n_sparse:   int,
	driver:     int, // -1 = table-driven

	// estado table-driven
	arch_idx: int,
	arch:     ^Archetype,
	row:      int,

	// estado sparse-driven
	dense_idx: int,

	entity: Entity, // válida após query_next() == true
}

query :: proc(w: ^World, types: ..typeid) -> Query {
	q := Query {
		w         = w,
		driver    = -1,
		arch_idx  = -1,
		row       = -1,
		dense_idx = -1,
	}
	for t in types {
		c := component_id(w, t)
		if si := w.sparse_of[int(c)]; si >= 0 {
			assert(q.n_sparse < MAX_QUERY_SPARSE, "muitos componentes sparse na query")
			q.sparse[q.n_sparse] = int(si)
			q.n_sparse += 1
		} else {
			mask_set(&q.table_mask, c)
		}
	}
	// driver = menor sparse set (menos entidades para varrer)
	if q.n_sparse > 0 {
		best := max(int)
		for k in 0 ..< q.n_sparse {
			n := len(w.sparse_sets[q.sparse[k]].entities)
			if n < best {
				best = n
				q.driver = q.sparse[k]
			}
		}
	}
	return q
}

query_next :: proc(q: ^Query) -> bool {
	if q.driver < 0 {
		// ---- table-driven ----
		q.row += 1
		for {
			if q.arch != nil && q.row < len(q.arch.entities) {
				q.entity = q.arch.entities[q.row]
				return true
			}
			q.arch = nil
			q.row = 0
			q.arch_idx += 1
			if q.arch_idx >= len(q.w.archetypes) do return false
			a := &q.w.archetypes[q.arch_idx]
			if mask_contains(a.mask, q.table_mask) && len(a.entities) > 0 {
				q.arch = a
			}
		}
	}

	// ---- sparse-driven ----
	drv := &q.w.sparse_sets[q.driver]
	for {
		q.dense_idx += 1
		if q.dense_idx >= len(drv.entities) do return false
		e := drv.entities[q.dense_idx]

		loc := q.w.locs[int(e)]
		if loc.arch < 0 do continue
		if !mask_contains(q.w.archetypes[loc.arch].mask, q.table_mask) do continue

		ok := true
		for k in 0 ..< q.n_sparse {
			si := q.sparse[k]
			if si == q.driver do continue
			if !ss_has(&q.w.sparse_sets[si], e) {
				ok = false
				break
			}
		}
		if !ok do continue

		q.entity = e
		q.arch = &q.w.archetypes[loc.arch]
		q.row = int(loc.row)
		return true
	}
}

query_get :: proc(q: ^Query, $T: typeid) -> ^T {
	c := component_id(q.w, T)

	if si := int(q.w.sparse_of[int(c)]); si >= 0 {
		declared := false
		for k in 0 ..< q.n_sparse {
			if q.sparse[k] == si {
				declared = true
				break
			}
		}
		assert(declared, "componente sparse não declarado na query")
		ss := &q.w.sparse_sets[si]
		assert(ss.elem_size > 0, "componente tag (size 0) não tem dados")
		return (^T)(ss_ptr(ss, q.entity))
	}

	assert(mask_has(q.table_mask, c), "componente não declarado na query")
	ci := q.arch.col_of[int(c)]
	assert(ci >= 0, "componente tag (size 0) não tem dados")
	return (^T)(column_ptr(&q.arch.columns[ci], q.row))
}

query_entity :: proc(q: ^Query) -> Entity {
	return q.entity
}

sparse_count :: proc(w: ^World, $T: typeid) -> int {
	c := component_id(w, T)
	si := w.sparse_of[int(c)]
	if si < 0 do return 0
	return len(w.sparse_sets[si].entities)
}

// ============================================================
// DEMO: batalha de horda densa
//
//   90 monstros (Time A) + Player  vs  90 monstros (Time B),
//   todos misturados numa área pequena. Todo frame:
//     - cada unidade viva e não-atordoada adquire o inimigo
//       mais próximo no alcance -> Attack_Intent (SPARSE:
//       ~180 inserts + ~180 removes por frame, zero migração)
//     - player solta uma nova em área a cada 3 frames,
//       aplicando Bleeding (SPARSE) em dezenas de alvos
//     - Bleeding pinga dano por tick PELA MESMA fila de
//       eventos dos ataques normais
//     - hits >= 24 de dano aplicam Stunned (SPARSE), que
//       impede a vítima de atacar no frame seguinte
// ============================================================

// --- Componentes TABLE (estáveis, vida inteira) ---

Transform :: struct {
	x, y: f32,
}
Health :: struct {
	current, max: f32,
}
Combat_Stats :: struct {
	attack:   f32,
	defense:  f32,
	accuracy: f32,
	range:    f32,
}
Team :: struct {
	id: int,
}

// --- Componentes SPARSE (voláteis, entram e saem todo frame) ---

Attack_Intent :: struct {
	target: Entity,
}
Bleeding :: struct {
	dps:       f32,
	remaining: f32,
}
Stunned :: struct {
	remaining: f32,
}

// --- Eventos ---

Damage_Event :: struct {
	source, target: Entity,
	amount:         f32,
	hit:            bool,
	dot:            bool, // dano de status effect
}

Frame_Events :: struct {
	combat: [dynamic]Damage_Event,
	deaths: [dynamic]Entity,
}

// --- RNG determinístico ---

rng_state: u64 = 0x9E3779B97F4A7C15

rand_f32 :: proc() -> f32 {
	rng_state ~= rng_state << 13
	rng_state ~= rng_state >> 7
	rng_state ~= rng_state << 17
	return f32(rng_state >> 40) / f32(1 << 24)
}

// --- Tuning ---

DT :: f32(0.1)
AOE_RADIUS :: f32(14)
AOE_DAMAGE :: f32(26)
STUN_THRESHOLD :: f32(24)
STUN_DURATION :: f32(0.3)
BLEED_DPS :: f32(40)
BLEED_DURATION :: f32(1.2)

// ------------------------------------------------------------------
// Systems
// ------------------------------------------------------------------

// 1) Status effects: tick de duração + dano por tempo.
//    Iteração sparse-driven: varre SÓ quem está sangrando,
//    não as 180+ entidades do mundo. O dano de bleed entra na
//    MESMA fila que ataques normais — um único caminho de
//    aplicação de dano para o jogo inteiro.
system_status_tick :: proc(w: ^World, ev: ^Frame_Events, cb: ^Commands, dt: f32) {
	{
		q := query(w, Bleeding, Health)
		for query_next(&q) {
			e := query_entity(&q)
			b := query_get(&q, Bleeding)
			append(&ev.combat, Damage_Event{source = e, target = e, amount = b.dps * dt, hit = true, dot = true})
			b.remaining -= dt
			if b.remaining <= 0 do cmd_remove(cb, e, Bleeding)
		}
	}
	{
		q := query(w, Stunned)
		for query_next(&q) {
			s := query_get(&q, Stunned)
			s.remaining -= dt
			if s.remaining <= 0 do cmd_remove(cb, query_entity(&q), Stunned)
		}
	}
}

// 2) IA: cada unidade adquire o inimigo mais próximo no alcance.
//    Atordoados são pulados com um lookup O(1) no sparse set.
Unit :: struct {
	e:     Entity,
	team:  int,
	x, y:  f32,
	range: f32,
}

system_ai :: proc(w: ^World, cb: ^Commands) {
	units := make([dynamic]Unit, 0, 256, context.temp_allocator)
	{
		q := query(w, Team, Transform, Combat_Stats, Health)
		for query_next(&q) {
			t := query_get(&q, Transform)
			append(&units, Unit{
				e     = query_entity(&q),
				team  = query_get(&q, Team).id,
				x     = t.x,
				y     = t.y,
				range = query_get(&q, Combat_Stats).range,
			})
		}
	}

	for u in units {
		if has(w, u.e, Stunned) do continue // O(1), sem tocar archetype

		best := ENTITY_NIL
		best_d2 := u.range * u.range
		for v in units {
			if v.team == u.team do continue
			dx := v.x - u.x
			dy := v.y - u.y
			d2 := dx * dx + dy * dy
			if d2 <= best_d2 {
				best_d2 = d2
				best = v.e
			}
		}
		if best != ENTITY_NIL {
			cmd_set(cb, u.e, Attack_Intent{target = best})
		}
	}
}

// 3) AoE do player: dano direto + Bleeding em todos no raio.
//    Dezenas de inserts sparse num frame só — barato.
system_player_aoe :: proc(w: ^World, ev: ^Frame_Events, cb: ^Commands, player: Entity) {
	pt := get(w, player, Transform)
	if pt == nil do return
	px, py := pt.x, pt.y

	n := 0
	q := query(w, Team, Transform, Health, Combat_Stats)
	for query_next(&q) {
		if query_get(&q, Team).id != 2 do continue
		t := query_get(&q, Transform)
		dx := t.x - px
		dy := t.y - py
		if dx * dx + dy * dy > AOE_RADIUS * AOE_RADIUS do continue

		e := query_entity(&q)
		def := query_get(&q, Combat_Stats).defense
		append(&ev.combat, Damage_Event{source = player, target = e, amount = max(AOE_DAMAGE - def, 1), hit = true})
		cmd_set(cb, e, Bleeding{dps = BLEED_DPS, remaining = BLEED_DURATION})
		n += 1
	}
	if n > 0 do fmt.println("  >>> Player lança NOVA DE SANGUE:", n, "alvos atingidos e sangrando")
}

// 4) Resolução: consome intenções (query sparse-driven sobre
//    Attack_Intent), rola acerto, calcula dano. Não escreve Health.
system_resolve_attacks :: proc(w: ^World, ev: ^Frame_Events, cb: ^Commands) {
	q := query(w, Attack_Intent, Combat_Stats)
	for query_next(&q) {
		e := query_entity(&q)
		intent := query_get(&q, Attack_Intent)
		stats := query_get(&q, Combat_Stats)

		cmd_remove(cb, e, Attack_Intent) // consumida (diferido)

		if get(w, intent.target, Health) == nil do continue

		hit := rand_f32() < stats.accuracy
		amount: f32 = 0
		if hit {
			defense: f32 = 0
			if ts := get(w, intent.target, Combat_Stats); ts != nil do defense = ts.defense
			amount = max(stats.attack - defense, 1)
		}
		append(&ev.combat, Damage_Event{source = e, target = intent.target, amount = amount, hit = hit})
	}
}

// 5) Aplicação: único escritor de Health do jogo.
system_apply_damage :: proc(w: ^World, ev: ^Frame_Events) {
	for d in ev.combat {
		if !d.hit do continue
		hp := get(w, d.target, Health)
		if hp == nil do continue
		hp.current = max(hp.current - d.amount, 0)
	}
}

// 6) Efeitos on-hit: pancada forte atordoa.
//    Regra de gameplay nova = system novo lendo a mesma fila;
//    nada nos systems anteriores mudou.
system_on_hit_effects :: proc(w: ^World, ev: ^Frame_Events, cb: ^Commands) {
	for d in ev.combat {
		if d.hit && !d.dot && d.amount >= STUN_THRESHOLD {
			if has(w, d.target, Health) {
				cmd_set(cb, d.target, Stunned{remaining = STUN_DURATION})
			}
		}
	}
}

// 7) Morte: destruição diferida; destroy_entity limpa os
//    sparse sets automaticamente (mortos não sangram).
system_death :: proc(w: ^World, ev: ^Frame_Events, cb: ^Commands) {
	q := query(w, Health)
	for query_next(&q) {
		if query_get(&q, Health).current > 0 do continue
		e := query_entity(&q)
		append(&ev.deaths, e)
		cmd_destroy(cb, e)
	}
}

// ------------------------------------------------------------------
// Helpers da demo
// ------------------------------------------------------------------

spawn_monster :: proc(w: ^World, team: int, x, y: f32) {
	e := create_entity(w)
	set(w, e, Transform{x, y})
	set(w, e, Health{70, 70})
	set(w, e, Combat_Stats{attack = 14, defense = 4, accuracy = 0.7, range = 10})
	set(w, e, Team{team})
}

count_team :: proc(w: ^World, team: int) -> int {
	n := 0
	q := query(w, Team, Health)
	for query_next(&q) {
		if query_get(&q, Team).id == team do n += 1
	}
	return n
}

print_summary :: proc(w: ^World, ev: ^Frame_Events, frame: int, player: Entity) {
	atk, dot_ticks, hits := 0, 0, 0
	dmg: f32 = 0
	for d in ev.combat {
		if d.dot {
			dot_ticks += 1
		} else {
			atk += 1
		}
		if d.hit do dmg += d.amount
		if d.hit && !d.dot do hits += 1
	}
	php: f32 = 0
	if hp := get(w, player, Health); hp != nil do php = hp.current

	fmt.printf(
		"FRAME %v | ataques: %v (acertos: %v) | DoT ticks: %v | dano: %.0f | mortes: %v | sangrando: %v | stun: %v | A: %v vs B: %v | Player HP: %.0f\n",
		frame, atk, hits, dot_ticks, dmg, len(ev.deaths),
		sparse_count(w, Bleeding), sparse_count(w, Stunned),
		count_team(w, 1), count_team(w, 2), php,
	)
}

// ------------------------------------------------------------------
// Main
// ------------------------------------------------------------------

main :: proc() {
	w: World
	world_init(&w)
	defer world_destroy(&w)

	// componentes voláteis -> sparse (ANTES do primeiro uso)
	register(&w, Attack_Intent, .Sparse)
	register(&w, Bleeding, .Sparse)
	register(&w, Stunned, .Sparse)

	cb: Commands
	defer commands_destroy(&cb)

	ev: Frame_Events
	defer {
		delete(ev.combat)
		delete(ev.deaths)
	}

	// Player (Time A)
	player := create_entity(&w)
	set(&w, player, Transform{50, 50})
	set(&w, player, Health{400, 400})
	set(&w, player, Combat_Stats{attack = 30, defense = 12, accuracy = 0.9, range = 8})
	set(&w, player, Team{1})

	// Horda densa: 90 vs 90, todos misturados numa área 40x40
	for _ in 0 ..< 90 {
		spawn_monster(&w, 1, 30 + rand_f32() * 40, 30 + rand_f32() * 40)
		spawn_monster(&w, 2, 30 + rand_f32() * 40, 30 + rand_f32() * 40)
	}

	fmt.println("Batalha: 90 + Player (Time A)  vs  90 (Time B)\n")

	for frame in 1 ..= 20 {
		if count_team(&w, 1) == 0 || count_team(&w, 2) == 0 do break

		// fase de status + intenção
		system_status_tick(&w, &ev, &cb, DT)
		system_ai(&w, &cb)
		if frame % 3 == 1 && has(&w, player, Health) {
			system_player_aoe(&w, &ev, &cb, player)
		}
		commands_flush(&w, &cb) // materializa intents/bleeds/expirações

		// pipeline de combate
		system_resolve_attacks(&w, &ev, &cb)
		system_apply_damage(&w, &ev)
		system_on_hit_effects(&w, &ev, &cb)
		system_death(&w, &ev, &cb)
		commands_flush(&w, &cb)

		print_summary(&w, &ev, frame, player)
		clear(&ev.combat)
		clear(&ev.deaths)
		free_all(context.temp_allocator)
	}

	fmt.println("\n=== Fim da batalha ===")
	a := count_team(&w, 1)
	b := count_team(&w, 2)
	switch {
	case a > 0 && b == 0:
		fmt.println("Time A (com o Player) venceu! Sobreviventes:", a)
	case b > 0 && a == 0:
		fmt.println("Time B venceu! Sobreviventes:", b)
	case:
		fmt.println("Batalha interrompida. A:", a, "vs B:", b)
	}

	// A prova do sparse-set: mesmo com ~180 Attack_Intent + dezenas
	// de Bleeding/Stunned entrando e saindo TODO frame, o número de
	// archetypes não explodiu — componentes sparse não migram tabela.
	fmt.println("Archetypes criados no mundo inteiro:", len(w.archetypes))
}
