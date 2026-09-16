#!/bin/bash
# 构建 TrafficLight.app 与 trafficlight CLI
# 用法: bash scripts/build_app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

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
chmod +x "$APP/Contents/Resources/trafficlight"
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
chmod +x "$ROOT/dist/trafficlight"

echo ""
echo "✅ 构建完成"
echo "   App: $APP"
echo "   CLI: $ROOT/dist/trafficlight"
