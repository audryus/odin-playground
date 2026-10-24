#define _GNU_SOURCE
#include "proc.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static volatile sig_atomic_t quit_flag = 0;

static void on_quit(int sig) { (void)sig; quit_flag = 1; }

void sh_signals_init(void) {
	signal(SIGPIPE, SIG_IGN);
	struct sigaction sa = {0};
	sa.sa_handler = on_quit;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGINT,  &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP,  &sa, NULL);
}

int sh_should_quit(void) { return quit_flag; }

int32_t sh_spawn(const char *const *argv, const char *cwd, const char *const *extra_env,
                 int32_t *in_fd, int32_t *out_fd) {
	int in_pipe[2], out_pipe[2];
	if (pipe2(in_pipe, O_CLOEXEC) < 0) return -1;
	if (pipe2(out_pipe, O_CLOEXEC) < 0) {
		close(in_pipe[0]); close(in_pipe[1]);
		return -1;
	}

	// envp is built before fork: the child must not allocate.
	int n_env = 0, n_extra = 0;
	while (environ[n_env]) n_env++;
	while (extra_env && extra_env[n_extra]) n_extra++;
	char **envp = malloc(sizeof(char *) * (size_t)(n_env + n_extra + 1));
	int k = 0;
	for (int i = 0; i < n_extra; i++) envp[k++] = (char *)extra_env[i];
	for (int i = 0; i < n_env; i++) {
		// Extra variables override inherited ones.
		int dup = 0;
		const char *eq = strchr(environ[i], '=');
		size_t klen = eq ? (size_t)(eq - environ[i]) + 1 : strlen(environ[i]);
		for (int j = 0; j < n_extra; j++)
			if (strncmp(environ[i], extra_env[j], klen) == 0) { dup = 1; break; }
		if (!dup) envp[k++] = environ[i];
	}
	envp[k] = NULL;

	pid_t parent = getpid();
	pid_t pid = fork();
	if (pid < 0) {
		free(envp);
		close(in_pipe[0]); close(in_pipe[1]);
		close(out_pipe[0]); close(out_pipe[1]);
		return -1;
	}
	if (pid == 0) {
		setpgid(0, 0);
		prctl(PR_SET_PDEATHSIG, SIGTERM);
		if (getppid() != parent) _exit(1); // parent died before prctl
		signal(SIGPIPE, SIG_DFL);
		dup2(in_pipe[0], 0);
		dup2(out_pipe[1], 1);
		if (cwd && chdir(cwd) < 0) _exit(127);
		execvpe(argv[0], (char *const *)argv, envp);
		_exit(127);
	}

	free(envp);
	close(in_pipe[0]);
	close(out_pipe[1]);
	fcntl(in_pipe[1], F_SETFL, O_NONBLOCK);
	fcntl(out_pipe[0], F_SETFL, O_NONBLOCK);
	*in_fd  = in_pipe[1];
	*out_fd = out_pipe[0];
	return pid;
}

void sh_kill_group(int32_t pid) {
	if (pid > 0) kill(-pid, SIGTERM);
}

int sh_reap(int32_t pid) {
	int status;
	pid_t r = waitpid(pid, &status, WNOHANG);
	return r == pid || (r < 0 && errno == ECHILD);
}

int sh_write(int32_t fd, const void *data, int32_t len) {
	return (int)write(fd, data, (size_t)len);
}

int sh_capture(const char *cmd, char *out, int32_t out_len) {
	if (out_len <= 0) return -1;
	out[0] = 0;
	FILE *f = popen(cmd, "r");
	if (!f) return -1;
	size_t n = fread(out, 1, (size_t)out_len - 1, f);
	pclose(f);
	out[n] = 0;
	return (int)n;
}
