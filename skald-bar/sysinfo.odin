package skald_bar

import "core:c/libc"
import "core:os"
import "core:strconv"
import "core:strings"

// Leituras baratas de /proc + relógio local. `sysinfo_tick` roda uma vez por
// segundo no loop principal.

Sysinfo :: struct {
	cpu_pct:   int,
	mem_used:  f64, // GiB
	mem_total: f64, // GiB
	clock:     [16]u8,
	clock_len: int,
	date:      [32]u8,
	date_len:  int,

	prev_idle, prev_total: u64,
}

sysinfo_init :: proc(s: ^Sysinfo) {
	// Data no idioma do sistema (LC_TIME / LANG) em vez do "C".
	libc.setlocale(.TIME, "")
	sysinfo_tick(s)
}

sysinfo_tick :: proc(s: ^Sysinfo) {
	read_cpu(s)
	read_mem(s)

	t := libc.time(nil)
	tm := libc.localtime(&t)
	s.clock_len = int(libc.strftime(&s.clock[0], len(s.clock), "%H:%M", tm))
	s.date_len  = int(libc.strftime(&s.date[0],  len(s.date),  "%a %d %b", tm))
}

sysinfo_clock :: proc(s: ^Sysinfo) -> string { return string(s.clock[:s.clock_len]) }
sysinfo_date  :: proc(s: ^Sysinfo) -> string { return string(s.date[:s.date_len]) }

@(private = "file")
read_cpu :: proc(s: ^Sysinfo) {
	data, err := os.read_entire_file("/proc/stat", context.temp_allocator)
	if err != nil { return }
	line := string(data)
	if i := strings.index_byte(line, '\n'); i >= 0 { line = line[:i] }

	// cpu  user nice system idle iowait irq softirq steal ...
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 5 { return }
	total, idle: u64
	for f, i in fields[1:] {
		v, _ := strconv.parse_u64(f)
		total += v
		if i == 3 || i == 4 { idle += v } // idle + iowait
	}
	if s.prev_total != 0 && total > s.prev_total {
		dt := total - s.prev_total
		di := idle - s.prev_idle
		s.cpu_pct = int(100 * (dt - di) / dt)
	}
	s.prev_total, s.prev_idle = total, idle
}

@(private = "file")
read_mem :: proc(s: ^Sysinfo) {
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil { return }
	total, avail: f64
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 { continue }
		v, _ := strconv.parse_f64(fields[1]) // kB
		switch fields[0] {
		case "MemTotal:":     total = v
		case "MemAvailable:": avail = v
		}
	}
	GIB :: 1024.0 * 1024.0
	s.mem_total = total / GIB
	s.mem_used  = (total - avail) / GIB
}
