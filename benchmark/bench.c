#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NANOS_PER_SEC 1000000000ull
#define KB 1024
#define MB 1024 * KB
#define GB 1024 * MB

static uint64_t time_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * NANOS_PER_SEC + (uint64_t)ts.tv_nsec;
}

int main() {
    char *a = malloc(GB+1);
    memset(a, 'a', GB);
    a[GB] = '0';
    uint64_t start = time_ns();
    fwrite(a, 1, GB+1, stdout);
    uint64_t d = time_ns() - start;
    printf("1GB in %luns - %llus\n", d, d / NANOS_PER_SEC);
    free(a);
    return 0;
}
