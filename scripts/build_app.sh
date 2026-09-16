#!/bin/bash
# 构建 TrafficLight.app 与 trafficlight CLI
# 用法: bash scripts/build_app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# 当前机器的 Command Line Tools 可能与 macOS SDK 版本不匹配；优先使用完整 Xcode。
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="release"
[[ "${1:-}" == "--debug" ]] && CONFIG="debug"

# 1. 归一化资源图（若缺失）
if [[ ! -f app/Sources/TrafficLight/Resources/red.png ]]; then
    echo "==> 归一化设计图"
    swift scripts/normalize_assets.swift raw app/Sources/TrafficLight/Resources
fi

# 2. 编译
echo "==> swift build ($CONFIG)"
BIN_DIR="$(swift build --package-path app -c "$CONFIG" --show-bin-path)"
swift build --package-path app -c "$CONFIG"

APP="$ROOT/dist/TrafficLight.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/TrafficLight" "$APP/Contents/MacOS/TrafficLight"
cp "$BIN_DIR/TrafficLightCLI" "$APP/Contents/Resources/trafficlight"
cp "$ROOT/scripts/trafficlight-run" "$APP/Contents/Resources/trafficlight-run"
cp "$ROOT/scripts/trafficlight-codex-hook" "$APP/Contents/Resources/trafficlight-codex-hook"
cp "$ROOT/scripts/trafficlight-workbuddy-hook" "$APP/Contents/Resources/trafficlight-workbuddy-hook"
cp "$ROOT/mcp/trafficlight_mcp.py" "$APP/Contents/Resources/trafficlight-mcp"
chmod +x "$APP/Contents/Resources/trafficlight" "$APP/Contents/Resources/trafficlight-run" "$APP/Contents/Resources/trafficlight-codex-hook" "$APP/Contents/Resources/trafficlight-workbuddy-hook" "$APP/Contents/Resources/trafficlight-mcp"
cp app/Sources/TrafficLight/Resources/red.png \
   app/Sources/TrafficLight/Resources/yellow.png \
   app/Sources/TrafficLight/Resources/green.png \
   "$APP/Contents/Resources/"

# SPM 资源 bundle（如果生成了）
if [[ -d "$BIN_DIR/TrafficLight_TrafficLight.bundle" ]]; then
    cp -R "$BIN_DIR/TrafficLight_TrafficLight.bundle" "$APP/Contents/Resources/"
fi

# 3. 图标
swift scripts/make_icon.swift raw/led.png "$APP/Contents/Resources/AppIcon.icns" >/dev/null

# 4. Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TrafficLight</string>
    <key>CFBundleDisplayName</key><string>TrafficLight</string>
    <key>CFBundleIdentifier</key><string>com.kzaven.trafficlight</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>TrafficLight</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# 5. Ad-hoc 签名（本地构建免 Gatekeeper 阻拦）
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

# 6. CLI 也放一份到 dist 便于直接测试
cp "$BIN_DIR/TrafficLightCLI" "$ROOT/dist/trafficlight"
cp "$ROOT/scripts/trafficlight-run" "$ROOT/dist/trafficlight-run"
cp "$ROOT/scripts/trafficlight-codex-hook" "$ROOT/dist/trafficlight-codex-hook"
cp "$ROOT/scripts/trafficlight-workbuddy-hook" "$ROOT/dist/trafficlight-workbuddy-hook"
cp "$ROOT/mcp/trafficlight_mcp.py" "$ROOT/dist/trafficlight-mcp"
chmod +x "$ROOT/dist/trafficlight" "$ROOT/dist/trafficlight-run" "$ROOT/dist/trafficlight-codex-hook" "$ROOT/dist/trafficlight-workbuddy-hook" "$ROOT/dist/trafficlight-mcp"

echo ""
echo "✅ 构建完成"
echo "   App: $APP"
echo "   CLI: $ROOT/dist/trafficlight"
