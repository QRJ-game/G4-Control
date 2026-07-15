typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef unsigned long size_t;

#define SYS_exit 1
#define SYS_fork 2
#define SYS_read 3
#define SYS_write 4
#define SYS_open 5
#define SYS_close 6
#define SYS_unlink 10
#define SYS_chdir 12
#define SYS_getpid 20
#define SYS_umask 60
#define SYS_setsid 66
#define SYS_nanosleep 162
#define SYS_ioctl 54
#define SYS_execve 11
#define SYS_dup2 63
#define SYS_wait4 114
#define SYS_socket 281
#define SYS_bind 282
#define SYS_connect 283
#define SYS_listen 284
#define SYS_accept 285
#define SYS_sendto 290
#define SYS_setsockopt 294

#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_RCVTIMEO 20
#define SO_SNDTIMEO 21
#define SIOCGIFADDR 0x8915
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 64
#define O_TRUNC 512
#define MSG_NOSIGNAL 0x4000

struct sockaddr_in {
    u16 sin_family;
    u16 sin_port;
    u32 sin_addr;
    u8 zero[8];
};

struct timeval32 {
    int tv_sec;
    int tv_usec;
};

struct timespec32 {
    int tv_sec;
    int tv_nsec;
};

struct ifreq_addr {
    char name[16];
    struct sockaddr_in address;
    char padding[8];
};

static long sc0(long n) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0");
    asm volatile("svc 0" : "=r"(r0) : "r"(r7) : "memory");
    return r0;
}

static long sc1(long n, long a) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    asm volatile("svc 0" : "+r"(r0) : "r"(r7) : "memory");
    return r0;
}

static long sc2(long n, long a, long b) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    register long r1 asm("r1") = b;
    asm volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r7) : "memory");
    return r0;
}

static long sc3(long n, long a, long b, long c) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    register long r1 asm("r1") = b;
    register long r2 asm("r2") = c;
    asm volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
    return r0;
}

static long sc4(long n, long a, long b, long c, long d) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    register long r1 asm("r1") = b;
    register long r2 asm("r2") = c;
    register long r3 asm("r3") = d;
    asm volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r7) : "memory");
    return r0;
}

static long sc5(long n, long a, long b, long c, long d, long e) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    register long r1 asm("r1") = b;
    register long r2 asm("r2") = c;
    register long r3 asm("r3") = d;
    register long r4 asm("r4") = e;
    asm volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory");
    return r0;
}

static long sc6(long n, long a, long b, long c, long d, long e, long f) {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a;
    register long r1 asm("r1") = b;
    register long r2 asm("r2") = c;
    register long r3 asm("r3") = d;
    register long r4 asm("r4") = e;
    register long r5 asm("r5") = f;
    asm volatile(
        "svc 0"
        : "+r"(r0)
        : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5), "r"(r7)
        : "memory"
    );
    return r0;
}

static size_t slen(const char *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

static int starts(const char *s, const char *prefix) {
    while (*prefix) {
        if (*s++ != *prefix++) return 0;
    }
    return 1;
}

static int seq(const char *a, const char *b) {
    while (*a && *b && *a == *b) {
        a++;
        b++;
    }
    return *a == 0 && *b == 0;
}

static void memzero(void *ptr, size_t n) {
    u8 *p = (u8 *)ptr;
    while (n--) *p++ = 0;
}

static void copy_name(char *destination, const char *source, int capacity) {
    int index = 0;

    while (index < capacity - 1 && source[index]) {
        destination[index] = source[index];
        index++;
    }

    destination[index] = 0;
}

static unsigned long divide_by_10(unsigned long value) {
    unsigned long quotient = (value >> 1) + (value >> 2);
    quotient += quotient >> 4;
    quotient += quotient >> 8;
    quotient += quotient >> 16;
    quotient >>= 3;

    unsigned long remainder = value - quotient * 10;
    return quotient + ((remainder + 6) >> 4);
}

static int unsigned_to_text(unsigned long value, char *buffer, int capacity) {
    char reverse[24];
    int length = 0;

    if (capacity < 2) return 0;

    if (value == 0) {
        buffer[0] = '0';
        buffer[1] = 0;
        return 1;
    }

    while (value && length < (int)sizeof(reverse)) {
        unsigned long quotient = divide_by_10(value);
        unsigned long remainder = value - quotient * 10;

        reverse[length++] = (char)('0' + remainder);
        value = quotient;
    }

    int output = 0;

    while (length > 0 && output < capacity - 1) {
        buffer[output++] = reverse[--length];
    }

    buffer[output] = 0;
    return output;
}

static int write_pidfile(const char *path) {
    char text[32];
    int length = unsigned_to_text(
        (unsigned long)sc0(SYS_getpid),
        text,
        sizeof(text)
    );

    if (length <= 0 || length >= (int)sizeof(text) - 1) return -1;

    text[length++] = '\n';

    long fd = sc3(
        SYS_open,
        (long)path,
        O_WRONLY | O_CREAT | O_TRUNC,
        0600
    );

    if (fd < 0) return -1;

    long written = sc3(SYS_write, fd, (long)text, length);
    sc1(SYS_close, fd);

    return written == length ? 0 : -1;
}

static void redirect_standard_fds(void) {
    long null_fd = sc3(SYS_open, (long)"/dev/null", O_RDWR, 0);

    if (null_fd < 0) {
        sc1(SYS_close, 0);
        sc1(SYS_close, 1);
        sc1(SYS_close, 2);
        return;
    }

    sc2(SYS_dup2, null_fd, 0);
    sc2(SYS_dup2, null_fd, 1);
    sc2(SYS_dup2, null_fd, 2);

    if (null_fd > 2) sc1(SYS_close, null_fd);
}

static int detach_process(void) {
    long first_child = sc0(SYS_fork);

    if (first_child < 0) return -1;

    if (first_child > 0) {
        int status = 0;
        sc4(SYS_wait4, first_child, (long)&status, 0, 0);
        return 1;
    }

    if (sc0(SYS_setsid) < 0) {
        sc1(SYS_exit, 31);
    }

    long second_child = sc0(SYS_fork);

    if (second_child < 0) {
        sc1(SYS_exit, 32);
    }

    if (second_child > 0) {
        sc1(SYS_exit, 0);
    }

    sc1(SYS_chdir, (long)"/");
    sc1(SYS_umask, 0);
    redirect_standard_fds();

    return 0;
}

static int daemon_exec(
    const char *script,
    const char *mode,
    const char *pidfile
) {
    int detached = detach_process();

    if (detached < 0) return 40;
    if (detached > 0) return 0;

    if (write_pidfile(pidfile) < 0) {
        sc1(SYS_exit, 41);
    }

    char *argv[] = {
        (char *)"sh",
        (char *)script,
        (char *)mode,
        0
    };
    char *envp[] = {
        (char *)"PATH=/bin:/sbin:/usr/bin:/usr/sbin",
        0
    };

    sc3(SYS_execve, (long)"/bin/sh", (long)argv, (long)envp);
    sc1(SYS_unlink, (long)pidfile);
    sc1(SYS_exit, 127);
    return 127;
}

static void sleep_seconds(int seconds) {
    struct timespec32 request;
    request.tv_sec = seconds;
    request.tv_nsec = 0;

    while (sc2(SYS_nanosleep, (long)&request, (long)&request) < 0) {
    }
}

static u32 interface_ipv4(const char *name) {
    long socket_fd = sc3(SYS_socket, AF_INET, SOCK_DGRAM, 0);
    if (socket_fd < 0) return 0;

    struct ifreq_addr request;
    memzero(&request, sizeof(request));
    copy_name(request.name, name, sizeof(request.name));

    long result = sc3(SYS_ioctl, socket_fd, SIOCGIFADDR, (long)&request);
    sc1(SYS_close, socket_fd);

    if (result < 0) return 0;
    return request.address.sin_addr;
}

static void send_all(int fd, const char *buffer, size_t n) {
    while (n) {
        long written = sc6(
            SYS_sendto,
            fd,
            (long)buffer,
            n,
            MSG_NOSIGNAL,
            0,
            0
        );

        if (written <= 0) return;
        buffer += written;
        n -= written;
    }
}

static void send_text(int fd, const char *status, const char *content_type, const char *body) {
    char header[640];
    size_t pos = 0;
    const char *parts[] = {
        "HTTP/1.1 ", status,
        "\r\nConnection: close\r\n",
        "Access-Control-Allow-Origin: *\r\n",
        "Access-Control-Allow-Methods: GET, OPTIONS\r\n",
        "Access-Control-Allow-Headers: Content-Type\r\n",
        "Access-Control-Allow-Private-Network: true\r\n",
        "Cross-Origin-Resource-Policy: cross-origin\r\n",
        "Content-Type: ", content_type,
        "\r\nCache-Control: no-store\r\n\r\n",
        0
    };

    for (int i = 0; parts[i]; i++) {
        const char *s = parts[i];
        while (*s && pos < sizeof(header)) header[pos++] = *s++;
    }

    send_all(fd, header, pos);
    send_all(fd, body, slen(body));
}

static int valid_op(const char *op) {
    const char *allowed[] = {
        "status",
        "wifi_off",
        "wifi_on",
        "public_on",
        "public_off",
        "public_status",
        "system_metrics",
        "watchdog_on",
        "watchdog_off",
        0
    };

    for (int i = 0; allowed[i]; i++) {
        if (seq(op, allowed[i])) return 1;
    }
    return 0;
}

static int run_action(const char *op, char *output, int capacity) {
    const char *result_path = "/tmp/g4-helper.out";
    sc1(SYS_unlink, (long)result_path);

    long pid = sc0(SYS_fork);
    if (pid == 0) {
        long fd = sc3(SYS_open, (long)result_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            sc2(SYS_dup2, fd, 1);
            sc2(SYS_dup2, fd, 2);
            if (fd > 2) sc1(SYS_close, fd);
        }

        char *argv[] = {
            (char *)"sh",
            (char *)"/mnt/userdata/g4ui/g4-actions.sh",
            (char *)op,
            0
        };
        char *envp[] = {0};

        sc3(SYS_execve, (long)"/bin/sh", (long)argv, (long)envp);
        sc1(SYS_exit, 127);
    }

    if (pid < 0) return -1;

    int status = 0;
    sc4(SYS_wait4, pid, (long)&status, 0, 0);

    long fd = sc3(SYS_open, (long)result_path, O_RDONLY, 0);
    if (fd < 0) {
        output[0] = 0;
        return 0;
    }

    long n = sc3(SYS_read, fd, (long)output, capacity - 1);
    sc1(SYS_close, fd);

    if (n < 0) n = 0;
    output[n] = 0;
    return (int)n;
}

static int capture_cells_from(u32 target_address, char *output, int capacity) {
    if (!target_address) return -1;

    long socket_fd = sc3(SYS_socket, AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0) return -1;

    struct timeval32 receive_timeout = {6, 0};
    struct timeval32 send_timeout = {3, 0};

    sc5(
        SYS_setsockopt,
        socket_fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        (long)&receive_timeout,
        sizeof(receive_timeout)
    );

    sc5(
        SYS_setsockopt,
        socket_fd,
        SOL_SOCKET,
        SO_SNDTIMEO,
        (long)&send_timeout,
        sizeof(send_timeout)
    );

    struct sockaddr_in address;
    memzero(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = (u16)((17820 >> 8) | ((17820 & 255) << 8));
    address.sin_addr = target_address;

    if (sc3(SYS_connect, socket_fd, (long)&address, sizeof(address)) < 0) {
        sc1(SYS_close, socket_fd);
        return -1;
    }

    int total = 0;

    while (total < capacity - 1) {
        long n = sc3(
            SYS_read,
            socket_fd,
            (long)(output + total),
            capacity - 1 - total
        );

        if (n <= 0) break;
        total += (int)n;
    }

    sc1(SYS_close, socket_fd);
    output[total] = 0;
    return total;
}

static int capture_cells(char *output, int capacity) {
    u32 candidates[3];
    candidates[0] = interface_ipv4("br0");
    candidates[1] = (u32)0x0100A8C0; /* 192.168.0.1 */
    candidates[2] = (u32)0x0100007F; /* 127.0.0.1 fallback */

    int connected = 0;

    for (int index = 0; index < 3; index++) {
        u32 address = candidates[index];
        if (!address) continue;

        int duplicate = 0;
        for (int previous = 0; previous < index; previous++) {
            if (candidates[previous] == address) duplicate = 1;
        }
        if (duplicate) continue;

        int count = capture_cells_from(address, output, capacity);

        if (count >= 0) {
            connected = 1;
            return count;
        }
    }

    if (!connected) return -1;
    return 0;
}

static void handle_client(int client_fd) {
    char request[4096];
    long n = sc3(SYS_read, client_fd, (long)request, sizeof(request) - 1);
    if (n <= 0) return;
    request[n] = 0;

    if (starts(request, "OPTIONS ")) {
        send_text(client_fd, "204 No Content", "text/plain; charset=utf-8", "");
        return;
    }

    if (starts(request, "GET /api/ping ") || starts(request, "GET /api/ping?")) {
        send_text(client_fd, "200 OK", "application/json; charset=utf-8",
                  "{\"ok\":true,\"version\":\"0.9.2\",\"port\":18081}");
        return;
    }

    if (starts(request, "GET /api/cells ") || starts(request, "GET /api/cells?")) {
        char output[12288];
        int count = capture_cells(output, sizeof(output));

        if (count < 0) {
            send_text(
                client_fd,
                "503 Service Unavailable",
                "text/plain; charset=utf-8",
                "G4_ERROR:zlbs_connect_failed"
            );
            return;
        }

        if (count == 0) output[0] = 0;
        send_text(client_fd, "200 OK", "text/plain; charset=utf-8", output);
        return;
    }

    if (starts(request, "GET /api/system ") || starts(request, "GET /api/system?")) {
        char output[16384];
        run_action("system_metrics", output, sizeof(output));
        send_text(client_fd, "200 OK", "text/plain; charset=utf-8", output);
        return;
    }

    if (starts(request, "GET /api/status ") || starts(request, "GET /api/status?")) {
        char output[8192];
        run_action("status", output, sizeof(output));
        send_text(client_fd, "200 OK", "text/plain; charset=utf-8", output);
        return;
    }

    if (starts(request, "GET /api/action?op=")) {
        char op[64];
        int i = 0;
        char *p = request + 19;

        while (*p && *p != ' ' && *p != '&' && i < 63) {
            char ch = *p++;
            if (!((ch >= 'a' && ch <= 'z') || ch == '_')) break;
            op[i++] = ch;
        }
        op[i] = 0;

        if (!valid_op(op)) {
            send_text(client_fd, "400 Bad Request", "application/json; charset=utf-8",
                      "{\"ok\":false,\"error\":\"bad op\"}");
            return;
        }

        char output[8192];
        run_action(op, output, sizeof(output));
        send_text(client_fd, "200 OK", "text/plain; charset=utf-8", output);
        return;
    }

    send_text(client_fd, "404 Not Found", "application/json; charset=utf-8",
              "{\"ok\":false,\"error\":\"not found\"}");
}

static int run_server(int daemon_mode) {
    if (daemon_mode) {
        int detached = detach_process();

        if (detached < 0) return 50;
        if (detached > 0) return 0;
    }

    long server_fd = sc3(SYS_socket, AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) return 2;

    int one = 1;
    sc5(
        SYS_setsockopt,
        server_fd,
        SOL_SOCKET,
        SO_REUSEADDR,
        (long)&one,
        sizeof(one)
    );

    struct sockaddr_in address;
    memzero(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = (u16)((18081 >> 8) | ((18081 & 255) << 8));
    address.sin_addr = 0;

    if (sc3(SYS_bind, server_fd, (long)&address, sizeof(address)) < 0) {
        sc1(SYS_close, server_fd);
        return 3;
    }

    if (sc2(SYS_listen, server_fd, 8) < 0) {
        sc1(SYS_close, server_fd);
        return 4;
    }

    if (daemon_mode) {
        if (write_pidfile("/tmp/g4-helper.pid") < 0) {
            sc1(SYS_close, server_fd);
            return 5;
        }
    }

    for (;;) {
        long client_fd = sc3(SYS_accept, server_fd, 0, 0);

        if (client_fd < 0) continue;

        handle_client((int)client_fd);
        sc1(SYS_close, client_fd);
    }

    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && seq(argv[1], "--self-test")) {
        long test_fd = sc3(SYS_socket, AF_INET, SOCK_STREAM, 0);

        if (test_fd < 0) return 20;

        sc1(SYS_close, test_fd);
        return 0;
    }

    if (argc > 1 && seq(argv[1], "--daemon-self-test")) {
        sc1(SYS_unlink, (long)"/tmp/g4-helper-daemon-selftest");

        int detached = detach_process();

        if (detached < 0) return 60;
        if (detached > 0) return 0;

        long fd = sc3(
            SYS_open,
            (long)"/tmp/g4-helper-daemon-selftest",
            O_WRONLY | O_CREAT | O_TRUNC,
            0600
        );

        if (fd < 0) sc1(SYS_exit, 61);

        const char ok[] = "G4_OK\n";
        sc3(SYS_write, fd, (long)ok, sizeof(ok) - 1);
        sc1(SYS_close, fd);
        sleep_seconds(1);
        sc1(SYS_exit, 0);
    }

    if (argc > 1 && seq(argv[1], "--daemon")) {
        return run_server(1);
    }

    if (argc > 1 && seq(argv[1], "--wifi-off-worker")) {
        return daemon_exec(
            "/mnt/userdata/g4ui/g4-actions.sh",
            "wifi_off_worker",
            "/tmp/g4-wifi-off.pid"
        );
    }

    if (argc > 1 && seq(argv[1], "--public-watcher")) {
        return daemon_exec(
            "/mnt/userdata/g4ui/g4-actions.sh",
            "public_watch",
            "/tmp/g4-public.pid"
        );
    }

    if (argc > 1 && seq(argv[1], "--cleaner-daemon")) {
        return daemon_exec(
            "/mnt/userdata/g4ui/g4-boot.sh",
            "cleaner-loop",
            "/tmp/g4ui-cleaner.pid"
        );
    }

    return run_server(0);
}

__attribute__((naked, section(".text.start")))
void _start(void) {
    asm volatile(
        "ldr r0, [sp]\n"      /* argc */
        "add r1, sp, #4\n"    /* argv */
        "bl main\n"
        "mov r7, #1\n"
        "svc #0\n"
    );
}
