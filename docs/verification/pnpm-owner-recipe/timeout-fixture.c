#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home || argc != 3 || strcmp(argv[1], "store")) return 91;
    if (!strcmp(argv[2], "path")) { printf("%s/store\n", home); return 0; }
    if (strcmp(argv[2], "prune")) return 92;
    /* This is observed inside the executable, before it starts any action. */
    if (getpgrp() != getpid()) return 96;
    const char *mode = getenv("LIFETIME_MODE");
    if (mode && !strcmp(mode, "output")) {
        char noise[4096]; memset(noise, 'x', sizeof(noise));
        for (int i = 0; i < 64; i++) {
            write(STDOUT_FILENO, noise, sizeof(noise));
            write(STDERR_FILENO, noise, sizeof(noise));
        }
        return 0;
    }
    pid_t child = fork();
    if (child < 0) return 93;
    if (child == 0) {
        if (getpgrp() != getppid()) return 97;
        signal(SIGTERM, SIG_IGN);
        char path[4096];
        snprintf(path, sizeof(path), "%s/child-heartbeat", home);
        /* More than the capture limit on both streams proves they are drained. */
        char noise[4096]; memset(noise, 'x', sizeof(noise));
        for (int i = 0; i < 64; i++) {
            write(STDOUT_FILENO, noise, sizeof(noise));
            write(STDERR_FILENO, noise, sizeof(noise));
        }
        for (int i = 0; i < 100; i++) {
            FILE *f = fopen(path, "a");
            if (!f) return 94;
            fprintf(f, "%d\n", i); fclose(f);
            if (i == 12) {
                char victim[4096];
                snprintf(victim, sizeof(victim), "%s/store/delayed-delete-victim", home);
                unlink(victim);
            }
            usleep(50000);
        }
        return 0;
    }
    char path[4096]; snprintf(path, sizeof(path), "%s/child-pid", home);
    FILE *f = fopen(path, "w"); if (!f) { kill(child, SIGKILL); return 95; }
    fprintf(f, "%d\n", child); fclose(f);
    if (mode && !strcmp(mode, "early-exit")) { usleep(100000); return 0; }
    waitpid(child, NULL, 0);
    return 0;
}
