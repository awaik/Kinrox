// Zero-secret parent-death reaper. Spotify is a direct child of Kinrox, not this helper.
#include <errno.h>
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

static int number(const char *text, unsigned long long *out) {
    if (!*text || *text == '-') return 0;
    char *end;
    errno = 0;
    *out = strtoull(text, &end, 10);
    return !errno && !*end;
}

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    unsigned long long pid_value, seconds, micros;
    if (!number(argv[1], &pid_value) || pid_value < 2 || pid_value > 2147483647 ||
        !number(argv[3], &seconds) || !number(argv[4], &micros) || micros >= 1000000) return 2;
    pid_t pid = (pid_t)pid_value;
    struct proc_bsdinfo original;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &original, sizeof(original)) != sizeof(original)) return 3;
    if (original.pbi_ppid != (uint32_t)getppid() || original.pbi_start_tvsec != seconds ||
        original.pbi_start_tvusec != micros || !same_process(pid, argv[2], &original)) return 3;
    puts("READY");
    fflush(stdout);
    char byte;
    while (1) {
        ssize_t count = read(STDIN_FILENO, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
    }
    if (same_process(pid, argv[2], &original)) kill(pid, SIGTERM);
    for (int i = 0; i < 50; i++) {
        if (!same_process(pid, argv[2], &original)) return 0;
        usleep(10000);
    }
    if (same_process(pid, argv[2], &original)) kill(pid, SIGKILL);
    return 0;
}
