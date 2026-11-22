#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 IPA 里的 .app 打成 Cydia 可安装的 .deb（越狱 root 模式，二进制 setuid root）"""
import io, os, sys, gzip, tarfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IPA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "artifact33", "WeChatVerFix.ipa")
VERSION = sys.argv[2] if len(sys.argv) > 2 else "2.0.0"
OUT = os.path.join(HERE, f"wechatverfix_{VERSION}_jailbreak.deb")

APP_PATH_IN_IPA = "Payload/WeChatVerFix.app"

control = f"""Package: com.local.wechatverfix
Name: 微版助手
Version: {VERSION}
Architecture: iphoneos-arm
Description: 微信「版本过低」修复工具。安装后二进制以 root 运行，可直接改写微信 Info.plist 的版本字段。适用于已越狱的 iOS 11~14。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 400
"""

postinst = """#!/bin/sh
APP=/Applications/WeChatVerFix.app

chown -R root:wheel "$APP" 2>/dev/null
chmod -R 755 "$APP" 2>/dev/null
chmod 644 "$APP"/*.png 2>/dev/null
chmod 644 "$APP"/Info.plist 2>/dev/null

# 主程序 setuid root：App 启动即拥有 root，才能写 _installd 拥有的微信文件
chown root:wheel "$APP"/WeChatVerFix
chmod 4755 "$APP"/WeChatVerFix

# 附带 root 助手（巨魔环境用；越狱环境可有可无）
if [ -f "$APP/wvfixd" ]; then
    chown root:wheel "$APP/wvfixd"
    chmod 755 "$APP/wvfixd"
fi

# 刷新桌面图标
if [ -x /usr/bin/uicache ]; then
    /usr/bin/uicache -a >/dev/null 2>&1
elif [ -x /usr/bin/sbreload ]; then
    /usr/bin/sbreload >/dev/null 2>&1
else
    killall -9 SpringBoard >/dev/null 2>&1
fi

exit 0
"""

postrm = """#!/bin/sh
if [ -x /usr/bin/uicache ]; then
    /usr/bin/uicache -a >/dev/null 2>&1
fi
exit 0
"""


def tar_gz(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
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


with zipfile.ZipFile(IPA) as z:
    names = [n for n in z.namelist() if n.startswith(APP_PATH_IN_IPA + "/") and not n.endswith("/")]

    app_entries = []
    for n in names:
        rel = n[len("Payload/"):]              # WeChatVerFix.app/xxx
        target = "./Applications/" + rel
        data = z.read(n)
        mode = 0o755 if rel.endswith("/WeChatVerFix") or rel.endswith("/wvfixd") else 0o644
        app_entries.append((target, data, mode))

# 目录项
dirs = {"./Applications", "./Applications/WeChatVerFix.app"}
for n, _, _ in app_entries:
    parts = n.split("/")
    for i in range(3, len(parts)):
        d = "/".join(parts[:i])
        if d and d not in dirs:
            dirs.add(d)

dir_entries = [(d + "/", b"", 0o755) for d in sorted(dirs)]
data_tar = tar_gz(dir_entries + app_entries)

control_tar = tar_gz([
    ("./control", control.encode(), 0o644),
    ("./postinst", postinst.encode(), 0o755),
    ("./postrm", postrm.encode(), 0o755),
])

deb = b"!<arch>\n"
deb += ar_member("debian-binary", b"2.0\n")
deb += ar_member("control.tar.gz", control_tar)
deb += ar_member("data.tar.gz", data_tar)

with open(OUT, "wb") as f:
    f.write(deb)

print("built:", OUT, os.path.getsize(OUT), "bytes")
print("app files:", len(app_entries))

# 自检
raw = open(OUT, "rb").read()
pos, mem = 8, {}
while pos + 60 <= len(raw):
    h = raw[pos:pos + 60].decode()
    name = h[0:16].strip()
    size = int(h[48:58].strip())
    pos += 60
    mem[name] = raw[pos:pos + size]
    pos += size + (size % 2)
print("deb members:", list(mem))
with tarfile.open(fileobj=io.BytesIO(gzip.decompress(mem["control.tar.gz"])), mode="r:") as tf:
    print("control members:", tf.getnames())
with tarfile.open(fileobj=io.BytesIO(gzip.decompress(mem["data.tar.gz"])), mode="r:") as tf:
    names = tf.getnames()
    print("data 顶层:", names[:6], "... 共", len(names), "项")
    for n in names:
        if n.endswith("WeChatVerFix") or n.endswith("wvfixd"):
            m = tf.getmember(n)
            print("  ", n, "mode", oct(m.mode))
