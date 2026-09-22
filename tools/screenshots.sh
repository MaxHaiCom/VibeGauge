#!/bin/bash
# 用演示数据重新生成 README 截图（离屏渲染，不截屏、不读本机真实用量）
set -e
cd "$(dirname "$0")/.."
OUT="${1:-assets/screenshots}"
BIN="$(mktemp -d)/screenshots"
swiftc -parse-as-library -target arm64-apple-macosx14.0 \
    -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework UserNotifications \
    $(ls Sources/*.swift | grep -v '/main.swift$') tools/screenshots.swift -o "$BIN"
"$BIN" "$OUT"
