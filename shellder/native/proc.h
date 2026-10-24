// proc — plugin fork/exec and process signals.
//
// Lives in C because between fork() and exec() the child may only make
// async-signal-safe calls; this keeps that explicit and independent of the
// Odin runtime.
#pragma once
#include <stdint.h>

// Ignores SIGPIPE and installs SIGINT/SIGTERM/SIGHUP handlers that only set
// a flag (read with sh_should_quit).
void sh_signals_init(void);
int  sh_should_quit(void);

// Starts argv[0] (looked up in PATH) with cwd and extra environment
// ("KEY=value", NULL-terminated). The child leads its own process group and
// gets SIGTERM if Shellder dies. Returns the pid or -1; *in_fd / *out_fd get
// the parent's ends (non-blocking, close-on-exec) of the child's stdin and
// stdout. stderr is inherited.
int32_t sh_spawn(const char *const *argv, const char *cwd, const char *const *extra_env,
                 int32_t *in_fd, int32_t *out_fd);

// Sends SIGTERM to the plugin's whole process group.
void sh_kill_group(int32_t pid);

// Reaps the child if it has exited. 1 = exited, 0 = still alive.
int  sh_reap(int32_t pid);

// Non-blocking write. Returns bytes written or -1.
int  sh_write(int32_t fd, const void *data, int32_t len);

// Runs `cmd` through /bin/sh and stores its stdout (NUL-terminated,
// truncated to out_len). Returns the number of bytes read, or -1. Blocking:
// only for quick commands (fc-match, hyprctl getoption).
int  sh_capture(const char *cmd, char *out, int32_t out_len);
