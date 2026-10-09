package main

import "core:fmt"

// ------------------------------------------------------------------
// Tipos base
// ------------------------------------------------------------------

Entity :: distinct int
Component :: distinct int

MAX_COMPONENTS :: 256
WORDS_PER_MASK :: MAX_COMPONENTS / 64

ComponentMask :: [WORDS_PER_MASK]u64

mask_set :: proc(m: ^ComponentMask, c: Component) {
	word := int(c) / 64; bit := int(c) % 64
	m[word] |= (1 << uint(bit))
}

mask_has :: proc(m: ComponentMask, c: Component) -> bool {
	word := int(c) / 64; bit := int(c) % 64
	return (m[word] & (1 << uint(bit))) != 0
}

mask_has_all :: proc(m, req: ComponentMask) -> bool {
	for w in 0 ..< WORDS_PER_MASK {
		if (m[w] & req[w]) != req[w] {return false}
	}
	return true
}

// ------------------------------------------------------------------
// Componentes (dados)
// ------------------------------------------------------------------

Health :: struct {
	current, max: f32,
}
Transform :: struct {
	x, y: f32,
}
Velocity :: struct {
	vx, vy: f32,
}

// ------------------------------------------------------------------
// Archetype = tabela de entidades com a mesma "assinatura"
// ------------------------------------------------------------------

Archetype :: struct {
	mask:      ComponentMask,
	entities:  [dynamic]Entity, // linha 0 -> entities[0]

	// SoA: cada array tem o mesmo comprimento, contíguo na memória
	health:    [dynamic]Health,
	transform: [dynamic]Transform,
	velocity:  [dynamic]Velocity,
}

// ------------------------------------------------------------------
// World
// ------------------------------------------------------------------

EntityLocation :: struct {
	archetype_idx: int,
	row_idx:       int, // índice dentro dos arrays do archetype
}

World :: struct {
	next_entity: int,
	archetypes:  [dynamic]Archetype,
	entity_loc:  [dynamic]EntityLocation, // entity_id -> onde ela está
}

world_init :: proc(w: ^World) {
	w.next_entity = 0
	// Archetype vazio (entidades sem componentes)
	append(&w.archetypes, Archetype{})
}

world_destroy :: proc(w: ^World) {
	for &a in w.archetypes {
		delete(a.entities)
		delete(a.health)
		delete(a.transform)
		delete(a.velocity)
	}
	delete(w.archetypes)
	delete(w.entity_loc)
}

// ------------------------------------------------------------------
// Criar entidade (começa no archetype vazio)
// ------------------------------------------------------------------

create_entity :: proc(w: ^World) -> Entity {
	e := Entity(w.next_entity)
	w.next_entity += 1

	append(
		&w.entity_loc,
		EntityLocation{archetype_idx = 0, row_idx = len(w.archetypes[0].entities)},
	)
	append(&w.archetypes[0].entities, e)

	return e
}

// ------------------------------------------------------------------
// Mover entidade entre archetypes (adicionar/remover componente)
// ------------------------------------------------------------------

move_entity :: proc(
	w: ^World,
	e: Entity,
	new_mask: ComponentMask,
	old_health: ^Health,
	old_transform: ^Transform,
	old_velocity: ^Velocity,
) {

	loc := &w.entity_loc[int(e)]
	old_arch := &w.archetypes[loc.archetype_idx]

	// --- Remover do archetype antigo (swap-and-pop) ---
	last_row := len(old_arch.entities) - 1
	moved_entity := old_arch.entities[last_row]

	// Copiar dados do último elemento para o buraco
	if loc.row_idx != last_row {
		old_arch.entities[loc.row_idx] = moved_entity
		if mask_has(
			old_arch.mask,
			Component(0),
		) {old_arch.health[loc.row_idx] = old_arch.health[last_row]}
		if mask_has(
			old_arch.mask,
			Component(1),
		) {old_arch.transform[loc.row_idx] = old_arch.transform[last_row]}
		if mask_has(
			old_arch.mask,
			Component(2),
		) {old_arch.velocity[loc.row_idx] = old_arch.velocity[last_row]}

		// Atualizar localização da entidade que foi movida
		w.entity_loc[int(moved_entity)].row_idx = loc.row_idx
	}

	pop(&old_arch.entities)
	if mask_has(old_arch.mask, Component(0)) {pop(&old_arch.health)}
	if mask_has(old_arch.mask, Component(1)) {pop(&old_arch.transform)}
	if mask_has(old_arch.mask, Component(2)) {pop(&old_arch.velocity)}

	// --- Encontrar ou criar novo archetype ---
	new_arch_idx := -1
	for a, i in w.archetypes {
		if a.mask == new_mask {
			new_arch_idx = i
			break
		}
	}

	if new_arch_idx == -1 {
		// Criar novo archetype
		new_arch := Archetype {
			mask = new_mask,
		}
		append(&w.archetypes, new_arch)
		new_arch_idx = len(w.archetypes) - 1
	}

	new_arch := &w.archetypes[new_arch_idx]
	new_row := len(new_arch.entities)

	// --- Inserir no novo archetype ---
	append(&new_arch.entities, e)
	if mask_has(new_mask, Component(0)) {
		val := Health{}; if old_health != nil {val = old_health^}
		append(&new_arch.health, val)
	}
	if mask_has(new_mask, Component(1)) {
		val := Transform{}; if old_transform != nil {val = old_transform^}
		append(&new_arch.transform, val)
	}
	if mask_has(new_mask, Component(2)) {
		val := Velocity{}; if old_velocity != nil {val = old_velocity^}
		append(&new_arch.velocity, val)
	}

	loc.archetype_idx = new_arch_idx
	loc.row_idx = new_row
}

// ------------------------------------------------------------------
// Adicionar componentes
// ------------------------------------------------------------------

Comp_Health :: Component(0)
Comp_Transform :: Component(1)
Comp_Velocity :: Component(2)

add_health :: proc(w: ^World, e: Entity, hp: f32) {
	loc := w.entity_loc[int(e)]
	arch := &w.archetypes[loc.archetype_idx]

	new_mask := arch.mask
	mask_set(&new_mask, Comp_Health)

	// Pegar dados atuais (pode ser nil se não existir)
	h: ^Health = nil; t: ^Transform = nil; v: ^Velocity = nil
	if mask_has(arch.mask, Comp_Health) {h = &arch.health[loc.row_idx]}
	if mask_has(arch.mask, Comp_Transform) {t = &arch.transform[loc.row_idx]}
	if mask_has(arch.mask, Comp_Velocity) {v = &arch.velocity[loc.row_idx]}

	// Sobrescrever com o novo valor
	new_h := h^ if h != nil else Health{}
	new_h.current = hp; new_h.max = hp

	move_entity(w, e, new_mask, &new_h, t, v)
}

add_transform :: proc(w: ^World, e: Entity, x, y: f32) {
	loc := w.entity_loc[int(e)]
	arch := &w.archetypes[loc.archetype_idx]

	new_mask := arch.mask
	mask_set(&new_mask, Comp_Transform)

	h: ^Health = nil; t: ^Transform = nil; v: ^Velocity = nil
	if mask_has(arch.mask, Comp_Health) {h = &arch.health[loc.row_idx]}
	if mask_has(arch.mask, Comp_Transform) {t = &arch.transform[loc.row_idx]}
	if mask_has(arch.mask, Comp_Velocity) {v = &arch.velocity[loc.row_idx]}

	new_t := t^ if t != nil else Transform{}
	new_t.x = x; new_t.y = y

	move_entity(w, e, new_mask, h, &new_t, v)
}

add_velocity :: proc(w: ^World, e: Entity, vx, vy: f32) {
	loc := w.entity_loc[int(e)]
	arch := &w.archetypes[loc.archetype_idx]

	new_mask := arch.mask
	mask_set(&new_mask, Comp_Velocity)

	h: ^Health = nil; t: ^Transform = nil; v: ^Velocity = nil
	if mask_has(arch.mask, Comp_Health) {h = &arch.health[loc.row_idx]}
	if mask_has(arch.mask, Comp_Transform) {t = &arch.transform[loc.row_idx]}
	if mask_has(arch.mask, Comp_Velocity) {v = &arch.velocity[loc.row_idx]}

	new_v := v^ if v != nil else Velocity{}
	new_v.vx = vx; new_v.vy = vy

	move_entity(w, e, new_mask, h, t, &new_v)
}

// ------------------------------------------------------------------
// Acesso direto (usado dentro de sistemas, já sabendo o archetype)
// ------------------------------------------------------------------

get_health :: proc(arch: ^Archetype, row: int) -> ^Health {
	return &arch.health[row]
}

get_transform :: proc(arch: ^Archetype, row: int) -> ^Transform {
	return &arch.transform[row]
}

get_velocity :: proc(arch: ^Archetype, row: int) -> ^Velocity {
	return &arch.velocity[row]
}

// ------------------------------------------------------------------
// Queries (a mágica do cache)
// ------------------------------------------------------------------

query_mask :: proc(comps: ..Component) -> ComponentMask {
	m: ComponentMask
	for c in comps {mask_set(&m, c)}
	return m
}

// Itera archetypes que contêm a máscara, e para cada um, itera as linhas contiguamente
query :: proc(w: ^World, req: ComponentMask, callback: proc(arch: ^Archetype, row: int)) {
	for &arch in w.archetypes {
		if mask_has_all(arch.mask, req) {
			// AQUI ESTÁ O CACHE HIT: iteramos 0..N sequencialmente
			for row in 0 ..< len(arch.entities) {
				callback(&arch, row)
			}
		}
	}
}

// ------------------------------------------------------------------
// Sistemas (cache-friendly!)
// ------------------------------------------------------------------

system_damage :: proc(w: ^World) {
	fmt.println("\n=== Sistema de Dano ===")

	// Aplica 10 de dano em todas entidades com Health
	q := query_mask(Comp_Health)
	query(w, q, proc(arch: ^Archetype, row: int) {
		hp := get_health(arch, row)
		hp.current -= 10
		e := arch.entities[row]
		fmt.println("Entity", e, "HP:", hp.current, "/", hp.max)
	})
}

system_move :: proc(w: ^World) {
	fmt.println("\n=== Sistema de Movimento ===")

	// Entidades com Transform + Velocity
	q := query_mask(Comp_Transform, Comp_Velocity)
	query(w, q, proc(arch: ^Archetype, row: int) {
		t := get_transform(arch, row)
		v := get_velocity(arch, row)
		t.x += v.vx
		t.y += v.vy
		e := arch.entities[row]
		fmt.println("Entity", e, "moveu para (", t.x, ",", t.y, ")")
	})
}

system_render :: proc(w: ^World) {
	fmt.println("\n=== Sistema de Render ===")

	// Só precisa de Transform
	q := query_mask(Comp_Transform)
	query(w, q, proc(arch: ^Archetype, row: int) {
		t := get_transform(arch, row)
		e := arch.entities[row]
		fmt.println("Entity", e, "render em (", t.x, ",", t.y, ")")
	})
}

// ------------------------------------------------------------------
// Main
// ------------------------------------------------------------------

main :: proc() {
	world: World
	world_init(&world)
	defer world_destroy(&world)

	// Criar entidades
	player := create_entity(&world)
	enemy := create_entity(&world)
	wall := create_entity(&world)
	bullet := create_entity(&world)

	// Composição:
	// Player: Health + Transform + Velocity
	add_health(&world, player, 100)
	add_transform(&world, player, 0, 0)
	add_velocity(&world, player, 5, 0)

	// Enemy: Health + Transform
	add_health(&world, enemy, 50)
	add_transform(&world, enemy, 20, 10)

	// Wall: só Transform
	add_transform(&world, wall, 5, 5)

	// Bullet: Transform + Velocity
	add_transform(&world, bullet, 0, 0)
	add_velocity(&world, bullet, 20, 0)

	// Rodar sistemas
	system_move(&world)
	system_damage(&world)
	system_render(&world)

	// Verificar archetypes criados
	fmt.println("\n=== Archetypes ===")
	for a, i in world.archetypes {
		fmt.println("Archetype", i, "-", len(a.entities), "entidades, mask:", a.mask)
	}
}
