#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 Cydia/Sileo 源（同时提供 rootless 与 rootful 两个包）"""
import gzip
import hashlib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VERSION = sys.argv[1] if len(sys.argv) > 1 else "2.1.0"
REPO = os.path.join(HERE, "repo")
os.makedirs(os.path.join(REPO, "debs"), exist_ok=True)

pkgs = [
    ("wechatverfix_%s_rootless.deb" % VERSION, "iphoneos-arm64", "iOS 15~16 越狱（Dopamine / XinaA15 等 rootless），装到 /var/jb"),
    ("wechatverfix_%s_rootful.deb" % VERSION, "iphoneos-arm", "iOS 11~14 越狱（checkra1n / unc0ver / Taurine，rootful），装到 /"),
]

desc_common = ("微信「当前版本过低无法登录」修复工具。安装后会常驻一个 root 守护进程，"
               "App 通过本地 socket 请求它把微信 Info.plist 里的版本字段改成新版本号。"
               "卡密激活、一机一码、可解绑。")

sections = []
for fname, arch, note in pkgs:
    src = os.path.join(HERE, fname)
    if not os.path.isfile(src):
        print("[skip] 缺少", fname)
        continue
    dst = os.path.join(REPO, "debs", fname)
    shutil.copyfile(src, dst)
    data = open(dst, "rb").read()
    sections.append(
        f"""Package: com.local.wechatverfix
Name: 微版助手
Version: {VERSION}
Architecture: {arch}
Description: {desc_common} {note}。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 500
Filename: debs/{fname}
Size: {len(data)}
MD5sum: {hashlib.md5(data).hexdigest()}
SHA256: {hashlib.sha256(data).hexdigest()}
""")

packages = "\n".join(sections)
open(os.path.join(REPO, "Packages"), "w", encoding="utf-8", newline="\n").write(packages)
open(os.path.join(REPO, "Packages.gz"), "wb").write(gzip.compress(packages.encode("utf-8"), mtime=0))

release = """Origin: shitou6688
Label: 微版助手源
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm iphoneos-arm64
Components: main
Description: 微版助手 · 微信版本伪装
"""
open(os.path.join(REPO, "Release"), "w", encoding="utf-8", newline="\n").write(release)

deblist = "\n".join(
    f'  <li><a href="debs/{f}">{f}</a></li>' for f, _, _ in pkgs
)
index = f"""<!doctype html><meta charset="utf-8">
<title>微版助手 · Cydia 源</title>
<style>body{{font-family:-apple-system,"PingFang SC",sans-serif;max-width:680px;margin:60px auto;padding:0 20px;line-height:1.8;color:#222}}
code{{background:#f4f6f5;padding:3px 8px;border-radius:6px;font-size:15px}}
li{{margin:4px 0}}</style>
<h2>微版助手 · Cydia 源</h2>
<p>在 Cydia / Sileo / Zebra 里添加源：</p>
<p><code>https://shitou6688.github.io/wvfix-repo/</code></p>
<p>搜索「微版助手」安装。会自动按你的越狱类型选择对应的包：</p>
<ul>
<li>rootless（Dopamine、XinaA15，iOS 15~16）→ 装到 /var/jb</li>
<li>rootful（checkra1n、unc0ver、Taurine，iOS 11~14）→ 装到 /</li>
</ul>
<h3>直接下载</h3>
<ul>
{deblist}
</ul>
"""
open(os.path.join(REPO, "index.html"), "w", encoding="utf-8", newline="\n").write(index)

print("repo 已生成:", REPO)
for root, _, files in os.walk(REPO):
    for f in sorted(files):
        p = os.path.join(root, f)
        print("  ", os.path.relpath(p, REPO), os.path.getsize(p))
print("\n--- Packages ---")
print(packages)
