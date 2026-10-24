// proc — fork/exec dos plugins e sinais do processo.
//
// Fica em C porque o filho, entre fork() e exec(), só pode fazer chamadas
// async-signal-safe; aqui isso é explícito e não depende do runtime do Odin.
#pragma once
#include <stdint.h>

// Ignora SIGPIPE e instala handlers de SIGINT/SIGTERM/SIGHUP que só marcam
// uma flag (lida com sh_should_quit).
void sh_signals_init(void);
int  sh_should_quit(void);

// Inicia argv[0] (procurado no PATH) com cwd e variáveis extras
// ("CHAVE=valor", terminado em NULL). O filho vira líder do próprio grupo de
// processos e recebe SIGTERM se o Shellder morrer. Devolve o pid ou -1; em
// *in_fd / *out_fd ficam as pontas do pai (não bloqueantes, close-on-exec)
// do stdin e stdout do filho. stderr é herdado.
int32_t sh_spawn(const char *const *argv, const char *cwd, const char *const *extra_env,
                 int32_t *in_fd, int32_t *out_fd);

// Manda SIGTERM para o grupo inteiro do plugin.
void sh_kill_group(int32_t pid);

// Recolhe o filho se ele já terminou. 1 = terminou, 0 = ainda vivo.
int  sh_reap(int32_t pid);

// Escreve sem bloquear. Devolve bytes escritos ou -1.
int  sh_write(int32_t fd, const void *data, int32_t len);

// Roda `cmd` via /bin/sh e guarda o stdout (terminado em \0, truncado em
// out_len). Devolve o número de bytes lidos, ou -1. Bloqueia: só para
// comandos rápidos (fc-match, hyprctl getoption).
int  sh_capture(const char *cmd, char *out, int32_t out_len);
