#!/bin/zsh
# 从两个原视频重新生成素材到 assets/（一般不需要再跑，素材已经生成好）
# source.mp4：biubiu 小猫绿幕视频；source2.mp4：三猫合跳视频
set -e
cd "$(dirname "$0")"
mkdir -p build/tools assets
cat tools/export.swift tools/edges.swift.inc > build/tools/export.swift
cat tools/companions.swift tools/edges.swift.inc > build/tools/companions.swift
swiftc -O build/tools/export.swift -o build/tools/export
swiftc -O build/tools/companions.swift -o build/tools/companions
./build/tools/export source.mp4 assets
./build/tools/companions source2.mp4 assets
