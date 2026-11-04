// Native macOS process counters. Never reads argv, environment, audio or credentials.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end || pid < 2 || pid > 2147483647) return 2;
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage)) return 3;
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return 4;
    // XNU fill_task_rusage copies Mach absolute CPU ticks, not nanoseconds.
    unsigned long long user_ns = (unsigned long long)
        ((__uint128_t)usage.ri_user_time * scale.numer / scale.denom);
    unsigned long long system_ns = (unsigned long long)
        ((__uint128_t)usage.ri_system_time * scale.numer / scale.denom);
    printf("{\"pid\":%ld,\"start_ticks\":%llu,\"physical_footprint_bytes\":%llu,\"resident_bytes\":%llu,"
           "\"user_ns\":%llu,\"system_ns\":%llu,\"interrupt_wakeups\":%llu,"
           "\"platform_idle_wakeups\":%llu,\"timebase_numer\":%u,\"timebase_denom\":%u}\n",
           pid, usage.ri_proc_start_abstime, usage.ri_phys_footprint, usage.ri_resident_size,
           user_ns, system_ns, usage.ri_interrupt_wkups,
           usage.ri_pkg_idle_wkups, scale.numer, scale.denom);
    return 0;
}
