#!/bin/sh
# 在 Mac 上本地编译（可选，云端 Actions 更省事）
set -e
cd "$(dirname "$0")/WeChatVerFix"

command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
command -v ldid     >/dev/null 2>&1 || brew install ldid

xcodegen generate
xcodebuild -project WeChatVerFix.xcodeproj -scheme WeChatVerFix \
  -sdk iphoneos -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP=$(find build -maxdepth 6 -name "WeChatVerFix.app" -type d | head -1)
rm -rf ipa_root && mkdir -p ipa_root/Payload
cp -R "$APP" ipa_root/Payload/
ldid -SWeChatVerFix/entitlements.plist ipa_root/Payload/WeChatVerFix.app/WeChatVerFix
( cd ipa_root && zip -qry ../WeChatVerFix.ipa Payload )

echo "产出: $(pwd)/WeChatVerFix.ipa"
