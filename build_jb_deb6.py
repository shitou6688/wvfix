#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
越狱 deb 生成器 v2.1.5 —— 自包含 postinst 版

经验（连续踩坑）：
  · Dopamine 的 dpkg 路径映射不可靠，data.tar 里的文件可能在 postinst 运行时
    不在预期位置（报 tar: ... Cannot open: No such file or directory）
  · 但 postinst 本身一定能被执行

所以：data.tar 只放一个占位文件，真正的「守护进程 + App 载荷」全部用 base64
内嵌进 postinst，运行时解码写盘，再解包、chown、注册 LaunchDaemon。
"""
import base64
import io
import os
import sys
import gzip
import tarfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IPA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "artifact35", "WeChatVerFix.ipa")
DAEMON = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "wvfdaemon_bin")
VERSION = sys.argv[3] if len(sys.argv) > 3 else "2.1.5"

APP_NAME = "WeChatVerFix.app"
APP_IN_IPA = "Payload/" + APP_NAME


def tar_gz(entries, with_dirs=False, compress=True):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        if with_dirs:
            dirs = set()
            for name, _, _ in entries:
                parts = name.split("/")
                for i in range(1, len(parts)):
                    dirs.add("/".join(parts[:i]) + "/")
            for d in sorted(dirs):
                ti = tarfile.TarInfo(d)
                ti.size = 0
                ti.mode = 0o755
                ti.uid = ti.gid = 0
                ti.mtime = 0
                tf.addfile(ti)
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.mtime = 0
            tf.addfile(ti, io.BytesIO(data))
    data = raw.getvalue()
    return gzip.compress(data, mtime=0) if compress else data


def ar_member(name, data):
    hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, "100644", len(data))
    out = hdr.encode() + data
    if len(data) % 2:
        out += b"\n"
    return out


def b64_lines(data, width=76):
    s = base64.b64encode(data).decode("ascii")
    return "\n".join(s[i:i + width] for i in range(0, len(s), width))


POSTINST_HEAD = """#!/bin/sh
# 微版助手安装脚本（自包含：载荷以 base64 内嵌）
set +e

PREFIX="@@PREFIX@@"
LIBEXEC="$PREFIX/usr/libexec"
APP_PARENT="$PREFIX/Applications"
APP_DIR="$APP_PARENT/@@APP_NAME@@"
PLIST_DIR="$PREFIX/Library/LaunchDaemons"
PLIST="$PLIST_DIR/com.local.wvfdaemon.plist"
DAEMON="$LIBEXEC/wvfdaemon"
PAYLOAD="/tmp/wvfix-app.tar"
LOG="/var/mobile/Documents/wvfix-install.log"

mkdir -p /var/mobile/Documents
: > "$LOG"
exec >> "$LOG" 2>&1
echo "===== wvfix install $(date) ====="
echo "PREFIX=$PREFIX"

decode() {
    src="$1"; dst="$2"
    if [ -x "$PREFIX/usr/bin/base64" ]; then
        "$PREFIX/usr/bin/base64" -d "$src" > "$dst" && return 0
    fi
    if command -v base64 >/dev/null 2>&1; then
        base64 -d "$src" > "$dst" && return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl base64 -d -in "$src" -out "$dst" && return 0
    fi
    return 1
}

mkdir -p "$LIBEXEC" "$APP_PARENT" "$PLIST_DIR"

# ---- 解码守护进程 ----
cat > /tmp/wvfdaemon.b64 <<'WVF_DAEMON_B64'
@@DAEMON_B64@@
WVF_DAEMON_B64
if decode /tmp/wvfdaemon.b64 "$DAEMON"; then
    chmod 755 "$DAEMON"
    chown root:wheel "$DAEMON"
    echo "daemon ok: $(ls -l "$DAEMON")"
else
    echo "daemon decode FAILED"
fi
rm -f /tmp/wvfdaemon.b64

# ---- 解码 App 载荷并解包 ----
cat > /tmp/wvfix-app.b64 <<'WVF_APP_B64'
@@APP_B64@@
WVF_APP_B64
if decode /tmp/wvfix-app.b64 "$PAYLOAD"; then
    echo "payload decoded: $(ls -l "$PAYLOAD")"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    tar -xf "$PAYLOAD" -C "$APP_PARENT"
    if [ ! -f "$APP_DIR/WeChatVerFix" ]; then
        echo "tar -xf failed, try gzip fallback"
        if [ -x "$PREFIX/usr/bin/gzip" ]; then
            "$PREFIX/usr/bin/gzip" -dc "$PAYLOAD" | tar -xf - -C "$APP_PARENT"
        fi
    fi
    echo "extracted: $(ls -l "$APP_PARENT")"
    echo "app files: $(ls -l "$APP_DIR" 2>/dev/null | head -8)"
else
    echo "payload decode FAILED"
fi
rm -f /tmp/wvfix-app.b64

# ---- 权限 ----
if [ -d "$APP_DIR" ]; then
    chown -R mobile:mobile "$APP_DIR"
    chmod -R 755 "$APP_DIR"
    chmod 755 "$APP_DIR/WeChatVerFix"
    chmod 644 "$APP_DIR/Info.plist"
    echo "app ok: $(ls -l "$APP_DIR" | head -5)"
else
    echo "app dir MISSING"
fi

# ---- LaunchDaemon ----
cat > "$PLIST" <<'WVF_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.local.wvfdaemon</string>
	<key>ProgramArguments</key>
	<array><string>@@DAEMON_PATH@@</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
WVF_PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

killall -9 wvfdaemon >/dev/null 2>&1
launchctl unload "$PLIST" >/dev/null 2>&1
launchctl load -w "$PLIST" >/dev/null 2>&1
echo "launchctl done"

# ---- 刷新桌面 ----
if [ -x "$PREFIX/usr/bin/uicache" ]; then
    "$PREFIX/usr/bin/uicache" -a >/dev/null 2>&1
elif [ -x /usr/bin/uicache ]; then
    /usr/bin/uicache -a >/dev/null 2>&1
fi

echo "===== done ====="
exit 0
"""

POSTRM = """#!/bin/sh
launchctl unload "@@PLIST@@" >/dev/null 2>&1
rm -f "@@PLIST@@"
killall -9 wvfdaemon >/dev/null 2>&1
rm -rf "@@APP_DIR@@"
exit 0
"""


def build_app_payload():
    entries = []
    with zipfile.ZipFile(IPA) as z:
        for n in z.namelist():
            if not n.startswith(APP_IN_IPA + "/") or n.endswith("/"):
                continue
            rel = n[len(APP_IN_IPA) + 1:]
            data = z.read(n)
            mode = 0o755 if rel in ("WeChatVerFix", "wvfixd", "wvfdaemon") else 0o644
            entries.append((APP_NAME + "/" + rel, data, mode))
    return tar_gz(entries, with_dirs=True, compress=False)


def build(kind):
    rootless = (kind == "rootless")
    prefix = "/var/jb" if rootless else ""
    arch = "iphoneos-arm64" if rootless else "iphoneos-arm"

    app_dir = prefix + "/Applications/" + APP_NAME
    plist_path = prefix + "/Library/LaunchDaemons/com.local.wvfdaemon.plist"
    daemon_path = prefix + "/usr/libexec/wvfdaemon"
    placeholder = prefix + "/usr/libexec/.wvfix-placeholder"

    payload = build_app_payload()
    daemon_bytes = open(DAEMON, "rb").read()

    postinst = POSTINST_HEAD
    postinst = postinst.replace("@@PREFIX@@", prefix)
    postinst = postinst.replace("@@APP_NAME@@", APP_NAME)
    postinst = postinst.replace("@@DAEMON_PATH@@", daemon_path)
    postinst = postinst.replace("@@DAEMON_B64@@", b64_lines(daemon_bytes))
    postinst = postinst.replace("@@APP_B64@@", b64_lines(payload))

    assert "@@" not in postinst, "postinst 仍有未替换占位"

    postrm = POSTRM.replace("@@PLIST@@", plist_path).replace("@@APP_DIR@@", app_dir)

    control = """Package: com.local.wechatverfix
Name: 微版助手
Version: @@VERSION@@
Architecture: @@ARCH@@
Description: 微信「当前版本过低无法登录」修复工具。安装时由 postinst 自行解码 App 与 root 守护进程，规避 dpkg 路径差异。卡密激活、一机一码、可解绑。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 700
""".replace("@@VERSION@@", VERSION).replace("@@ARCH@@", arch)

    control_tar = tar_gz([
        ("./control", control.encode(), 0o644),
        ("./postinst", postinst.encode(), 0o755),
        ("./postrm", postrm.encode(), 0o755),
    ])
    # data.tar 只放一个占位文件
    data_tar = tar_gz([("." + placeholder, b"wvfix\n", 0o644)])

    out = os.path.join(HERE, "wechatverfix_%s_%s.deb" % (VERSION, kind))
    deb = (b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
           + ar_member("control.tar.gz", control_tar)
           + ar_member("data.tar.gz", data_tar))
    open(out, "wb").write(deb)

    print("[%s] %s %d bytes arch=%s" % (kind, out, len(deb), arch))
    print("   postinst %d 字节（内嵌 base64 载荷）" % len(postinst))
    print("   App 装到: %s" % app_dir)
    return out


if __name__ == "__main__":
    if not os.path.isfile(DAEMON):
        sys.exit("缺少守护进程二进制: " + DAEMON)
    build("rootless")
    build("rootful")
