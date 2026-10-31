/*
 * Development probe, NOT a production transport. Connect first, without
 * sending content, and see whether libproc exposes the reverse TCP tuple in
 * the expected process. No user data is read or transmitted by this program.
 * This establishes only OS observability, not a security guarantee.
 *
 * clang -Wall -Wextra -Werror scripts/probe_managed_socket.c -o /tmp/after-socket-probe
 * /tmp/after-socket-probe PID PORT [--http]
 */
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int identity(pid_t pid, struct proc_bsdinfo *p) {
    memset(p, 0, sizeof(*p));
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, p, sizeof(*p)) == (int)sizeof(*p)
        && p->pbi_pid == (uint32_t)pid;
}

static int same_identity(const struct proc_bsdinfo *a, const struct proc_bsdinfo *b) {
    return a->pbi_pid == b->pbi_pid && a->pbi_start_tvsec == b->pbi_start_tvsec
        && a->pbi_start_tvusec == b->pbi_start_tvusec;
}

static int has_reverse_connection(pid_t pid, const struct sockaddr_in *local,
                                  const struct sockaddr_in *remote) {
    /* Reject a truncated descriptor list rather than returning a partial match. */
    struct proc_fdinfo list[16384];
    int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, list, sizeof(list));
    if (n <= 0 || n >= (int)sizeof(list) || n % sizeof(list[0]) != 0) return 0;
    for (size_t i = 0; i < (size_t)n / sizeof(list[0]); i++) {
        if (list[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo info;
        memset(&info, 0, sizeof(info));
        if (proc_pidfdinfo(pid, list[i].proc_fd, PROC_PIDFDSOCKETINFO,
                           &info, sizeof(info)) != (int)sizeof(info)) continue;
        if (info.psi.soi_kind != SOCKINFO_TCP || info.psi.soi_family != AF_INET) continue;
        const struct tcp_sockinfo *tcp = &info.psi.soi_proto.pri_tcp;
        const struct in_sockinfo *ip = &tcp->tcpsi_ini;
        if (tcp->tcpsi_state == TSI_S_ESTABLISHED && (ip->insi_vflag & INI_IPV4)
            && (uint16_t)ip->insi_lport == remote->sin_port
            && (uint16_t)ip->insi_fport == local->sin_port
            && ip->insi_laddr.ina_46.i46a_addr4.s_addr == remote->sin_addr.s_addr
            && ip->insi_faddr.ina_46.i46a_addr4.s_addr == local->sin_addr.s_addr) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if ((argc != 3 && argc != 4) || (argc == 4 && strcmp(argv[3], "--http"))) {
        fprintf(stderr, "usage: %s PID PORT [--http]\n", argv[0]); return 2;
    }
    char *end = NULL;
    long pid_num = strtol(argv[1], &end, 10);
    if (!end || *end || pid_num <= 0 || pid_num > INT32_MAX) return 2;
    long port = strtol(argv[2], &end, 10);
    if (!end || *end || port <= 0 || port > 65535) return 2;
    pid_t pid = (pid_t)pid_num;
    struct proc_bsdinfo before, after;
    if (!identity(pid, &before)) { fprintf(stderr, "process not observable\n"); return 1; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_in remote = {0}, local = {0};
    remote.sin_len = sizeof(remote); remote.sin_family = AF_INET;
    remote.sin_port = htons((uint16_t)port); remote.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t size = sizeof(local);
    if (connect(fd, (struct sockaddr *)&remote, sizeof(remote)) ||
        getsockname(fd, (struct sockaddr *)&local, &size) || size != sizeof(local)) {
        perror("connect/getsockname"); close(fd); return 1;
    }
    int found = 0;
    for (int i = 0; i < 100; i++) {
        if (has_reverse_connection(pid, &local, &remote)) { found = 1; break; }
        usleep(10000);
    }
    int unchanged = identity(pid, &after) && same_identity(&before, &after);
    if (!found || !unchanged) {
        close(fd);
        fprintf(stderr, "expected owner not observable on connected socket\n"); return 1;
    }
    if (argc == 4) {
        /* Send only a fixed public probe on this exact verified connection. */
        const char request[] = "GET /api/tags HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
        int no_sigpipe = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) ||
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))) {
            close(fd); fprintf(stderr, "could not bound probe socket\n"); return 1;
        }
        size_t sent = 0;
        while (sent < sizeof(request) - 1) {
            ssize_t n = write(fd, request + sent, sizeof(request) - 1 - sent);
            if (n <= 0) { close(fd); fprintf(stderr, "probe write failed\n"); return 1; }
            sent += (size_t)n;
        }
        char line[128] = {0};
        size_t used = 0;
        while (used < sizeof(line) - 1) {
            ssize_t n = read(fd, line + used, 1);
            if (n != 1) break;
            if (line[used++] == '\n') break;
        }
        if (strcmp(line, "HTTP/1.1 200 OK\r\n") != 0) {
            close(fd); fprintf(stderr, "probe received an unexpected HTTP status\n"); return 1;
        }
    }
    close(fd);
    puts("PASS: reverse connected tuple observed in expected process (probe only)");
    return 0;
}
