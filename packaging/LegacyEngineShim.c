// Preserve existing MCP configurations that point to posle-engine while the
// actual process uses the After name. No shell, environment or arguments are
// interpreted here; the operating system replaces this process with the
// adjacent signed executable, preserving stdio and the caller's arguments.
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    uint32_t size = 0;
    if (_NSGetExecutablePath(NULL, &size) != -1 || size == 0 || size > 1024 * 1024) {
        fputs("After Engine: cannot locate executable\n", stderr);
        return 127;
    }
    char *raw = malloc(size);
    if (raw == NULL || _NSGetExecutablePath(raw, &size) != 0) {
        free(raw);
        fputs("After Engine: cannot locate executable\n", stderr);
        return 127;
    }
    char *path = realpath(raw, NULL);
    free(raw);
    if (path == NULL) {
        fputs("After Engine: cannot resolve executable\n", stderr);
        return 127;
    }
    char *separator = strrchr(path, '/');
    if (separator == NULL) {
        free(path);
        fputs("After Engine: cannot locate bundle\n", stderr);
        return 127;
    }
    const char suffix[] = "/After Engine";
    size_t prefix = (size_t)(separator - path);
    char *target = malloc(prefix + sizeof(suffix));
    if (target == NULL) {
        free(path);
        fputs("After Engine: cannot allocate executable path\n", stderr);
        return 127;
    }
    memcpy(target, path, prefix);
    memcpy(target + prefix, suffix, sizeof(suffix));
    free(path);
    // Downstream libraries also derive their display name from argv[0].
    argv[0] = target;
    execv(target, argv);
    free(target);
    fputs("After Engine: cannot start bundled engine\n", stderr);
    return 127;
}
