// Probe-only parent-death cleanup. No credentials are accepted or inspected.
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

static int same_process(pid_t pid, const char *path, const struct proc_bsdinfo *original) {
    struct proc_bsdinfo current;
    char actual[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &current, sizeof(current)) != sizeof(current)) return 0;
    if (proc_pidpath(pid, actual, sizeof(actual)) <= 0) return 0;
    return current.pbi_uid == getuid() && strcmp(actual, path) == 0 &&
        current.pbi_start_tvsec == original->pbi_start_tvsec &&
        current.pbi_start_tvusec == original->pbi_start_tvusec;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char *end;
    long number = strtol(argv[1], &end, 10);
    if (*end || number < 2 || number > 2147483647) return 2;
    pid_t pid = (pid_t)number;
    struct proc_bsdinfo original;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &original, sizeof(original)) != sizeof(original)) return 3;
    if (!same_process(pid, argv[2], &original)) return 3;
    puts("READY");
    fflush(stdout);
    char byte;
    while (read(STDIN_FILENO, &byte, 1) > 0) {}
    if (same_process(pid, argv[2], &original)) kill(pid, SIGTERM);
    for (int i = 0; i < 50; i++) {
        if (!same_process(pid, argv[2], &original)) return 0;
        usleep(10000);
    }
    if (same_process(pid, argv[2], &original)) kill(pid, SIGKILL);
    return 0;
}
