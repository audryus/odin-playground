package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:time"

// ------------------------------------------------------------------
// Configuração
// ------------------------------------------------------------------

NUM_ENTITIES :: 500_000
ITERATIONS :: 200

// ------------------------------------------------------------------
// Tipos
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
// AOS - Array of Structs
// ------------------------------------------------------------------

EntityAOS :: struct {
	has_health:    bool,
	has_transform: bool,
	has_velocity:  bool,
	pad:           u8, // alinhar
	health:        Health,
	transform:     Transform,
	velocity:      Velocity,
}


benchmark_aos :: #force_no_inline proc(entities: []EntityAOS) -> f64 {
	// Usar o resultado para evitar otimização
	total_x: f32 = 0

	start := time.tick_now()
	for _ in 0 ..< ITERATIONS {
		for &e in entities {
			// Branch - mas padrão aleatório para não ser previsível
			if e.has_transform && e.has_velocity {
				e.transform.x += e.velocity.vx
				e.transform.y += e.velocity.vy
				total_x += e.transform.x
			}
		}
	}
	_ = total_x
	return time.duration_seconds(time.tick_since(start))
}

// ------------------------------------------------------------------
// SOA - Structure of Arrays (interleaved em um único bloco!)
// ------------------------------------------------------------------

// Alocar tudo em um único bloco contíguo para garantir proximidade
SoAData :: struct {
	transforms: []Transform,
	velocities: []Velocity,
	count:      int,
}

benchmark_soa :: #force_no_inline proc(data: SoAData) -> f64 {
	total_x: f32 = 0

	start := time.tick_now()
	for _ in 0 ..< ITERATIONS {
		// Sem branch, sem saltos, 100% sequencial
		#no_bounds_check for i in 0 ..< data.count {
			t := &data.transforms[i]
			v := &data.velocities[i]
			t.x += v.vx
			t.y += v.vy
			total_x += t.x
		}
	}
	_ = total_x
	return time.duration_seconds(time.tick_since(start))
}

// ------------------------------------------------------------------
// Sparse - Array de ponteiros (simula ECS com indireção)
// ------------------------------------------------------------------

EntitySparse :: struct {
	transform: ^Transform,
	velocity:  ^Velocity,
}

benchmark_sparse :: #force_no_inline proc(entities: []EntitySparse) -> f64 {
	total_x: f32 = 0

	start := time.tick_now()
	for _ in 0 ..< ITERATIONS {
		for &e in entities {
			e.transform.x += e.velocity.vx
			e.transform.y += e.velocity.vy
			total_x += e.transform.x
		}
	}
	_ = total_x
	return time.duration_seconds(time.tick_since(start))
}

// ------------------------------------------------------------------
// Inicialização
// ------------------------------------------------------------------

init_aos :: proc() -> []EntityAOS {
	entities := make([]EntityAOS, NUM_ENTITIES)

	// Padrão aleatório para branch não ser previsível
	for i in 0 ..< NUM_ENTITIES {
		entities[i].transform = Transform {
			x = rand.float32(),
			y = rand.float32(),
		}
		if rand.float32() > 0.5 {
			entities[i].has_transform = true
			entities[i].has_velocity = true
			entities[i].velocity = Velocity {
				vx = 1.0,
				vy = 2.0,
			}
		}
	}
	return entities
}

init_soa :: proc() -> SoAData {
	count := NUM_ENTITIES / 2

	total_size := size_of(Transform) * count + size_of(Velocity) * count
	raw := make([]u8, total_size)

	// Cast correta: &raw[0] pega ^u8, cast para [^]Transform (multi-pointer), [:count] vira slice
	transforms := ([^]Transform)(&raw[0])[:count]

	// Offset para a segunda array
	offset := size_of(Transform) * count
	velocities := ([^]Velocity)(&raw[offset])[:count]

	for i in 0 ..< count {
		transforms[i] = Transform {
			x = rand.float32(),
			y = rand.float32(),
		}
		velocities[i] = Velocity {
			vx = 1.0,
			vy = 2.0,
		}
	}

	return SoAData{transforms = transforms, velocities = velocities, count = count}
}

init_sparse :: proc() -> []EntitySparse {
	count := NUM_ENTITIES / 2
	entities := make([]EntitySparse, count)
	transforms := make([]Transform, count)
	velocities := make([]Velocity, count)

	for i in 0 ..< count {
		transforms[i] = Transform {
			x = rand.float32(),
			y = rand.float32(),
		}
		velocities[i] = Velocity {
			vx = 1.0,
			vy = 2.0,
		}
		entities[i].transform = &transforms[i]
		entities[i].velocity = &velocities[i]
	}
	return entities
}

// ------------------------------------------------------------------
// Main
// ------------------------------------------------------------------

// Helper para deletar SOA
raw_data :: proc(s: SoAData) -> []u8 {
	// Isso é um hack - na prática você guardaria o slice original
	return nil
}

// ------------------------------------------------------------------
// Main com argumento
// ------------------------------------------------------------------

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Uso: ./main <aos|soa|sparse>")
		fmt.println("  ou: ./main all    (roda comparativo)")
		os.exit(1)
	}

	mode := os.args[1]

	if mode == "all" {
		fmt.println("=== Preparando dados ===")
		aos_data := init_aos()
		soa_data := init_soa()
		sparse_data := init_sparse()

		defer {
			delete(aos_data)
			delete(raw_data(soa_data))
			delete(sparse_data)
		}

		fmt.println("Benchmarking with", NUM_ENTITIES, "entities,", ITERATIONS, "iterations")
		fmt.println("----------------------------------------------------------------")

		// Aquecer
		for _ in 0 ..< 5 {
			_ = benchmark_aos(aos_data)
			_ = benchmark_soa(soa_data)
			_ = benchmark_sparse(sparse_data)
		}

		// Medir
		runs := 10
		aos_total, soa_total, sparse_total: f64

		for _ in 0 ..< runs {
			aos_total += benchmark_aos(aos_data)
			soa_total += benchmark_soa(soa_data)
			sparse_total += benchmark_sparse(sparse_data)
		}

		aos_avg := aos_total / f64(runs)
		soa_avg := soa_total / f64(runs)
		sparse_avg := sparse_total / f64(runs)

		fmt.printf("AOS   (branch aleatório):  %.4f ms\n", aos_avg * 1000)
		fmt.printf("SOA   (sequencial puro):   %.4f ms\n", soa_avg * 1000)
		fmt.printf("Sparse (indireção):        %.4f ms\n", sparse_avg * 1000)
		fmt.println("----------------------------------------------------------------")

		if soa_avg < aos_avg {
			fmt.printf("SOA é %.1fx mais rápido que AOS ✅\n", aos_avg / soa_avg)
		} else {
			fmt.printf("SOA é %.1fx mais LENTO que AOS ❌\n", soa_avg / aos_avg)
		}

		return
	}

	// Modo isolado para profiling
	time_ms: f64
	switch mode {
	case "aos":
		data := init_aos()
		defer delete(data)
		// Aquecer
		for _ in 0 ..< 5 {_ = benchmark_aos(data)}
		time_ms = benchmark_aos(data) * 1000

	case "soa":
		data := init_soa()
		// defer delete(data) // cuidado com o raw pointer, ajuste seu init_soa
		for _ in 0 ..< 5 {_ = benchmark_soa(data)}
		time_ms = benchmark_soa(data) * 1000

	case "sparse":
		data := init_sparse()
		defer {
			delete(data)
			// delete dos arrays internos também
		}
		for _ in 0 ..< 5 {_ = benchmark_sparse(data)}
		time_ms = benchmark_sparse(data) * 1000

	case:
		fmt.println("Modo inválido:", mode)
		os.exit(1)
	}

	fmt.printf("TIME_MS: %.4f\n", time_ms)
}
