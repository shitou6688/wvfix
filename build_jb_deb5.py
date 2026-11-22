#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打越狱 deb（rootless / rootful），采用「载荷 tar + postinst 解包」：

  包内只有两个文件（都放进已存在的 /usr/libexec，不新增目录项）：
    <prefix>/usr/libexec/wvfdaemon        root 守护进程
    <prefix>/usr/libexec/wvfix-app.tar    App 载荷（内部含目录结构）

  postinst 以 root 运行：mkdir -p 目标目录 → tar 解包 App → 写 LaunchDaemon
  → chown/chmod → launchctl load → uicache

  这样 dpkg 只负责两个文件，不参与目录归属判断：
  既不会 `trying to overwrite '/var'`，也不会 `No such file or directory`。
"""
import io, os, sys, gzip, tarfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IPA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "artifact35", "WeChatVerFix.ipa")
DAEMON = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "wvfdaemon_bin")
VERSION = sys.argv[3] if len(sys.argv) > 3 else "2.1.4"

APP_NAME = "WeChatVerFix.app"
APP_IN_IPA = "Payload/" + APP_NAME

POSTINST = """#!/bin/sh
set +e

PREFIX="@@PREFIX@@"
APP_PARENT="@@APP_PARENT@@"
APP_DIR="@@APP_DIR@@"
PLIST_DIR="@@PLIST_DIR@@"
PLIST="@@PLIST@@"
PAYLOAD="@@PAYLOAD@@"
DAEMON="@@DAEMON@@"

mkdir -p "$APP_PARENT"
rm -rf "$APP_DIR"
tar -xf "$PAYLOAD" -C "$APP_PARENT"

chown -R mobile:mobile "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod 755 "$APP_DIR/WeChatVerFix"
chmod 644 "$APP_DIR/Info.plist"

chown root:wheel "$DAEMON"
chmod 755 "$DAEMON"

mkdir -p "$PLIST_DIR"
cat > "$PLIST" <<'WVFPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.local.wvfdaemon</string>
	<key>ProgramArguments</key>
	<array><string>@@DAEMON@@</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
WVFPLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

killall -9 wvfdaemon >/dev/null 2>&1
launchctl unload "$PLIST" >/dev/null 2>&1
launchctl load -w "$PLIST" >/dev/null 2>&1

if [ -x "$PREFIX/usr/bin/uicache" ]; then
    "$PREFIX/usr/bin/uicache" -a >/dev/null 2>&1
elif [ -x /usr/bin/uicache ]; then
    /usr/bin/uicache -a >/dev/null 2>&1
else
    killall -9 SpringBoard >/dev/null 2>&1
fi

exit 0
"""

POSTRM = """#!/bin/sh
launchctl unload "@@PLIST@@" >/dev/null 2>&1
rm -f "@@PLIST@@"
killall -9 wvfdaemon >/dev/null 2>&1
rm -rf "@@APP_DIR@@"
rm -f "@@PAYLOAD@@"
exit 0
"""


def tar_gz(entries, with_dirs=False):
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
                ti.uname = "root"
                ti.gname = "wheel"
                ti.mtime = 0
                tf.addfile(ti)
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = "root"
            ti.gname = "wheel"
            ti.mtime = 0
            tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), mtime=0)


def ar_member(name, data):
    hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, "100644", len(data))
    out = hdr.encode() + data
    if len(data) % 2:
        out += b"\n"
    return out


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
    return tar_gz(entries, with_dirs=True)


def build(kind):
    rootless = (kind == "rootless")
    prefix = "/var/jb" if rootless else ""
    arch = "iphoneos-arm64" if rootless else "iphoneos-arm"

    libexec = prefix + "/usr/libexec"
    app_parent = prefix + "/Applications"
    app_dir = app_parent + "/" + APP_NAME
    plist_dir = prefix + "/Library/LaunchDaemons"
    plist_path = plist_dir + "/com.local.wvfdaemon.plist"
    daemon_path = libexec + "/wvfdaemon"
    payload_path = libexec + "/wvfix-app.tar"

    payload = build_app_payload()

    data_tar = tar_gz([
        ("." + daemon_path, open(DAEMON, "rb").read(), 0o755),
        ("." + payload_path, payload, 0o644),
    ])

    control = """Package: com.local.wechatverfix
Name: 微版助手
Version: @@VERSION@@
Architecture: @@ARCH@@
Description: 微信「当前版本过低无法登录」修复工具。安装后常驻 root 守护进程，App 通过本地 socket 请求它改写信微 Info.plist 的版本字段。卡密激活、一机一码、可解绑。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 600
""".replace("@@VERSION@@", VERSION).replace("@@ARCH@@", arch)

    subs = [
        ("@@PREFIX@@", prefix),
        ("@@APP_PARENT@@", app_parent),
        ("@@APP_DIR@@", app_dir),
        ("@@PLIST_DIR@@", plist_dir),
        ("@@PLIST@@", plist_path),
        ("@@PAYLOAD@@", payload_path),
        ("@@DAEMON@@", daemon_path),
    ]

    postinst = POSTINST
    postrm = POSTRM
    for k, v in subs:
        postinst = postinst.replace(k, v)
        postrm = postrm.replace(k, v)

    assert "@@" not in postinst, "postinst 还有未替换的占位符"
    assert "@@" not in postrm, "postrm 还有未替换的占位符"

    control_tar = tar_gz([
        ("./control", control.encode(), 0o644),
        ("./postinst", postinst.encode(), 0o755),
        ("./postrm", postrm.encode(), 0o755),
    ])

    out = os.path.join(HERE, "wechatverfix_%s_%s.deb" % (VERSION, kind))
    deb = (b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
           + ar_member("control.tar.gz", control_tar) + ar_member("data.tar.gz", data_tar))
    open(out, "wb").write(deb)

    print("[%s] %s %d bytes arch=%s" % (kind, out, len(deb), arch))
    print("   包内文件: ./%s , ./%s" % (daemon_path.lstrip("/"), payload_path.lstrip("/")))
    print("   App 装到: %s" % app_dir)
    return out


if __name__ == "__main__":
    if not os.path.isfile(DAEMON):
        sys.exit("缺少守护进程二进制: " + DAEMON)
    build("rootless")
    build("rootful")
