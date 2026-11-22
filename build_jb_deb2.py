#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打两个越狱 deb：
  rootless  → Dopamine / XinaA15 等（iOS 15-16），全部装在 /var/jb 下，Architecture: iphoneos-arm64
  rootful   → checkra1n / unc0ver / Taurine 等（iOS 11-14），装在 /，Architecture: iphoneos-arm

两个包都包含：
  · App（WeChatVerFix.app）
  · root 守护进程 wvfdaemon
  · LaunchDaemon 开机自启
App 通过 /var/mobile/Documents/WeChatVerFix/wvf.sock 请求 root 操作，不依赖 setuid。
"""
import io, os, sys, gzip, tarfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "tool")
IPA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "artifact34", "WeChatVerFix.ipa")
DAEMON = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "wvfdaemon_bin")
VERSION = sys.argv[3] if len(sys.argv) > 3 else "2.1.0"

APP_IN_IPA = "Payload/WeChatVerFix.app"


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


daemon_plist_tpl = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.local.wvfdaemon</string>
	<key>ProgramArguments</key>
	<array><string>{daemon}</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
"""


def build(kind):
    rootless = (kind == "rootless")
    prefix = "/var/jb" if rootless else ""
    arch = "iphoneos-arm64" if rootless else "iphoneos-arm"

    app_dir = prefix + "/Applications/WeChatVerFix.app"
    daemon_path = prefix + "/usr/libexec/wvfdaemon"
    plist_path = prefix + "/Library/LaunchDaemons/com.local.wvfdaemon.plist"

    def tarpath(p):
        return "." + p

    entries = []
    with zipfile.ZipFile(IPA) as z:
        for n in z.namelist():
            if not n.startswith(APP_IN_IPA + "/") or n.endswith("/"):
                continue
            rel = n[len("Payload/"):].replace("WeChatVerFix.app/", "", 1)
            target = tarpath(app_dir + "/" + rel)
            data = z.read(n)
            mode = 0o755 if rel in ("WeChatVerFix", "wvfixd") else 0o644
            entries.append((target, data, mode))

    entries.append((tarpath(daemon_path), open(DAEMON, "rb").read(), 0o755))
    entries.append((tarpath(plist_path),
                    daemon_plist_tpl.format(daemon=daemon_path).encode(), 0o644))

    dirs = set()
    for name, _, _ in entries:
        parts = name.split("/")
        for i in range(2, len(parts)):
            dirs.add("/".join(parts[:i]) + "/")
    dir_entries = [(d, b"", 0o755) for d in sorted(dirs)]

    data_tar = tar_gz(dir_entries + entries)

    control = f"""Package: com.local.wechatverfix
Name: 微版助手
Version: {VERSION}
Architecture: {arch}
Description: 微信「当前版本过低无法登录」修复工具。安装后由 root 守护进程执行文件改写，支持 iOS 11 及以上越狱（rootless 与 rootful 均可）。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 500
"""

    postinst = f"""#!/bin/sh
APP="{app_dir}"
DAEMON="{daemon_path}"
PLIST="{plist_path}"

chown -R mobile:mobile "$APP" 2>/dev/null
chmod -R 755 "$APP" 2>/dev/null
chmod 644 "$APP"/Info.plist "$APP"/*.png 2>/dev/null
chmod 755 "$APP"/WeChatVerFix "$APP"/wvfixd 2>/dev/null

chown root:wheel "$DAEMON" 2>/dev/null
chmod 755 "$DAEMON" 2>/dev/null
chown root:wheel "$PLIST" 2>/dev/null
chmod 644 "$PLIST" 2>/dev/null

# 启动守护进程
launchctl unload "$PLIST" >/dev/null 2>&1
launchctl load -w "$PLIST" >/dev/null 2>&1

# 刷新桌面
if [ -x {prefix}/usr/bin/uicache ]; then
    {prefix}/usr/bin/uicache -a >/dev/null 2>&1
elif [ -x /usr/bin/uicache ]; then
    /usr/bin/uicache -a >/dev/null 2>&1
else
    killall -9 SpringBoard >/dev/null 2>&1
fi
exit 0
"""

    postrm = f"""#!/bin/sh
launchctl unload "{plist_path}" >/dev/null 2>&1
rm -f "{plist_path}"
killall -9 wvfdaemon >/dev/null 2>&1
exit 0
"""

    control_tar = tar_gz([
        ("./control", control.encode(), 0o644),
        ("./postinst", postinst.encode(), 0o755),
        ("./postrm", postrm.encode(), 0o755),
    ])

    out = os.path.join(HERE, f"wechatverfix_{VERSION}_{kind}.deb")
    deb = b"!<arch>\n" + ar_member("debian-binary", b"2.0\n") \
        + ar_member("control.tar.gz", control_tar) + ar_member("data.tar.gz", data_tar)
    open(out, "wb").write(deb)

    print(f"[{kind}] {out} {len(deb)} bytes")
    print(f"  app      : {app_dir}")
    print(f"  daemon   : {daemon_path}")
    print(f"  launchd  : {plist_path}")
    print(f"  arch     : {arch}")
    return out


if __name__ == "__main__":
    if not os.path.isfile(DAEMON):
        sys.exit("缺少守护进程二进制: " + DAEMON)
    build("rootless")
    build("rootful")
