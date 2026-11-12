//
//  wvfixd — 微信版本伪装的 root 助手
//  由主 app 用 persona spawn 以 uid=0 执行。
//
//  用法:
//    wvfixd --uid <输出文件>          把 getuid() 写进文件，确认拿到 root
//    wvfixd --kill <进程名>           按进程名 SIGKILL（iOS 没有 /usr/bin/killall）
//    wvfixd <源文件> <目标文件>        用源文件内容覆盖目标文件（可写 _installd 的文件）
//
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/param.h>

static int writeAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) return -1;
        p += n;
        left -= (size_t)n;
    }
    return 0;
}

// 按 p_comm 匹配进程名并 SIGKILL，返回杀掉的个数（<0 表示枚举失败）
static int killByName(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
    if (size == 0) return 0;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -2;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -3;
    }

    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t self = getpid();
    int killed = 0;

    for (int i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        pid_t pid = p->kp_proc.p_pid;
        if (pid <= 0 || pid == self) continue;
        if (strncmp(p->kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            if (kill(pid, SIGKILL) == 0) killed++;
        }
    }

    free(procs);
    return killed;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // wvfixd --uid <out>
        if (argc == 3 && strcmp(argv[1], "--uid") == 0) {
            NSString *out = [NSString stringWithUTF8String:argv[2]];
            NSString *text = [NSString stringWithFormat:@"uid=%d euid=%d gid=%d\n",
                              getuid(), geteuid(), getgid()];
            int fd = open(out.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) return 10;
            int r = writeAll(fd, text.UTF8String, strlen(text.UTF8String));
            close(fd);
            return r == 0 ? 0 : 11;
        }

        // wvfixd --kill <name>
        if (argc == 3 && strcmp(argv[1], "--kill") == 0) {
            int n = killByName(argv[2]);
            if (n < 0) return 20;
            return 0;   // 0 个也算成功（进程可能本来就没在跑）
        }

        // wvfixd <src> <dst>
        if (argc < 3) {
            fprintf(stderr, "usage: wvfixd --uid <out> | --kill <name> | <src> <dst>\n");
            return 2;
        }

        NSString *src = [NSString stringWithUTF8String:argv[1]];
        NSString *dst = [NSString stringWithUTF8String:argv[2]];

        NSData *data = [NSData dataWithContentsOfFile:src];
        if (!data) return 3;

        int fd = open(dst.fileSystemRepresentation, O_WRONLY | O_TRUNC);
        if (fd < 0) return 4;

        int r = writeAll(fd, data.bytes, data.length);
        fsync(fd);
        close(fd);
        if (r != 0) return 5;

        return 0;
    }
}
