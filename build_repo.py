#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 Cydia/Sileo 源目录（Packages / Packages.gz / Release + deb）"""
import gzip
import hashlib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "wechatverfix_2.0.0_jailbreak.deb")
VERSION = sys.argv[2] if len(sys.argv) > 2 else "2.0.0"
REPO = os.path.join(HERE, "repo")

os.makedirs(os.path.join(REPO, "debs"), exist_ok=True)
deb_name = os.path.basename(DEB)
dst = os.path.join(REPO, "debs", deb_name)
shutil.copyfile(DEB, dst)

data = open(dst, "rb").read()
size = len(data)
md5 = hashlib.md5(data).hexdigest()
sha256 = hashlib.sha256(data).hexdigest()

packages = f"""Package: com.local.wechatverfix
Name: 微版助手
Version: {VERSION}
Architecture: iphoneos-arm
Description: 微信「当前版本过低无法登录」修复工具。以 root 运行，可把微信 Info.plist 里的版本字段改成新版本号，支持 iOS 11 及以上越狱设备。
Maintainer: shitou6688
Author: shitou6688
Section: Applications
Depends: firmware (>= 11.0)
Installed-Size: 400
Filename: debs/{deb_name}
Size: {size}
MD5sum: {md5}
SHA256: {sha256}
"""

open(os.path.join(REPO, "Packages"), "w", encoding="utf-8", newline="\n").write(packages)

with open(os.path.join(REPO, "Packages.gz"), "wb") as f:
    f.write(gzip.compress(packages.encode("utf-8"), mtime=0))

release = """Origin: shitou6688
Label: 微版助手源
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm
Components: main
Description: 微版助手 · 微信版本伪装
"""

open(os.path.join(REPO, "Release"), "w", encoding="utf-8", newline="\n").write(release)

index = """<!doctype html><meta charset="utf-8">
<title>微版助手 · Cydia 源</title>
<style>body{font-family:-apple-system,"PingFang SC",sans-serif;max-width:640px;margin:60px auto;padding:0 20px;line-height:1.7;color:#222}
code{background:#f4f6f5;padding:2px 6px;border-radius:6px}</style>
<h2>微版助手 · Cydia 源</h2>
<p>在 Cydia / Sileo / Zebra 里添加源：</p>
<p><code>SOURCE_URL</code></p>
<p>然后搜索「微版助手」安装即可。</p>
<ul>
  <li><a href="Packages">Packages</a></li>
  <li><a href="debs/DEB_NAME">下载 deb</a></li>
</ul>
"""

index = index.replace("SOURCE_URL", "https://shitou6688.github.io/wvfix-repo/").replace("DEB_NAME", deb_name)
open(os.path.join(REPO, "index.html"), "w", encoding="utf-8", newline="\n").write(index)

print("repo dir:", REPO)
for root, _, files in os.walk(REPO):
    for f in files:
        p = os.path.join(root, f)
        print("  ", os.path.relpath(p, REPO), os.path.getsize(p))
print("\nPackages:\n" + packages)
