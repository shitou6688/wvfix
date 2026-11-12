//
//  wvfixd — 微信版本伪装的 root 助手
//  由主 app 用 persona spawn 以 uid=0 执行。
//  用法:
//    wvfixd --uid <输出文件>        把 getuid() 写进文件，用于确认确实拿到 root
//    wvfixd <源文件> <目标文件>      用源文件内容覆盖目标文件（root 身份，可写 _installd 的文件）
//
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

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

int main(int argc, char *argv[]) {
    @autoreleasepool {
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

        if (argc < 3) {
            fprintf(stderr, "usage: wvfixd <src> <dst> | wvfixd --uid <out>\n");
            return 2;
        }

        NSString *src = [NSString stringWithUTF8String:argv[1]];
        NSString *dst = [NSString stringWithUTF8String:argv[2]];

        NSData *data = [NSData dataWithContentsOfFile:src];
        if (!data) return 3;

        // 覆盖目标文件内容；文件已存在，只改内容不动属主
        int fd = open(dst.fileSystemRepresentation, O_WRONLY | O_TRUNC);
        if (fd < 0) return 4;

        int r = writeAll(fd, data.bytes, data.length);
        fsync(fd);
        close(fd);
        if (r != 0) return 5;

        return 0;
    }
}
