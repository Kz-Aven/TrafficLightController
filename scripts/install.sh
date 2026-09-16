#!/bin/bash
# 安装 TrafficLight：App 装入 /Applications，CLI 链接进 PATH，可选安装 Skill 和 Codex Hook。
# 用法: bash scripts/install.sh [--with-skill] [--with-codex-hooks] [--with-workbuddy-hooks] [--launch]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="TrafficLight.app"

# 1. 确保有构建产物
if [[ ! -d "$ROOT/dist/$APP_NAME" ]]; then
    bash "$ROOT/scripts/build_app.sh"
fi

# 2. 安装 App（/Applications 不可写则退回 ~/Applications）
APP_DIR="/Applications"
if [[ ! -w "$APP_DIR" ]]; then
    APP_DIR="$HOME/Applications"
    mkdir -p "$APP_DIR"
fi
echo "==> 安装 App 到 $APP_DIR"
rm -rf "$APP_DIR/$APP_NAME"
cp -R "$ROOT/dist/$APP_NAME" "$APP_DIR/$APP_NAME"

# 3. CLI 链接（优先 /usr/local/bin，其次 Homebrew bin，最后 ~/bin）
CLI_TARGET="$APP_DIR/$APP_NAME/Contents/Resources/trafficlight"
RUN_TARGET="$APP_DIR/$APP_NAME/Contents/Resources/trafficlight-run"
MCP_TARGET="$APP_DIR/$APP_NAME/Contents/Resources/trafficlight-mcp"
CODEX_HOOK_TARGET="$APP_DIR/$APP_NAME/Contents/Resources/trafficlight-codex-hook"
WORKBUDDY_HOOK_TARGET="$APP_DIR/$APP_NAME/Contents/Resources/trafficlight-workbuddy-hook"
BIN_DIR=""
for d in /usr/local/bin /opt/homebrew/bin; do
    if [[ -w "$d" ]]; then
        BIN_DIR="$d"
        break
    fi
done
if [[ -z "$BIN_DIR" ]]; then
    BIN_DIR="$HOME/bin"
    mkdir -p "$BIN_DIR"
    if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
        echo "⚠️  $BIN_DIR 不在 PATH 中，请将其加入 shell 配置：export PATH=\"$BIN_DIR:\$PATH\""
    fi
fi
echo "==> 链接 CLI 到 $BIN_DIR/trafficlight"
ln -sf "$CLI_TARGET" "$BIN_DIR/trafficlight"
ln -sf "$RUN_TARGET" "$BIN_DIR/trafficlight-run"
ln -sf "$MCP_TARGET" "$BIN_DIR/trafficlight-mcp"
ln -sf "$CODEX_HOOK_TARGET" "$BIN_DIR/trafficlight-codex-hook"
ln -sf "$WORKBUDDY_HOOK_TARGET" "$BIN_DIR/trafficlight-workbuddy-hook"

# 4. 安装 Skill（供 ZCode / Codex / WorkBuddy 等 Agent 使用）
if [[ " $* " == *" --with-skill "* ]]; then
    SKILL_DIR="$HOME/.agents/skills/traffic-light-controller"
    echo "==> 安装 Skill 到 $SKILL_DIR"
    mkdir -p "$SKILL_DIR"
    cp "$ROOT/SKILL.md" "$SKILL_DIR/SKILL.md"
fi

# 5. 配置 Codex 原生 Hook
if [[ " $* " == *" --with-codex-hooks "* ]]; then
    CODEX_DIR="$HOME/.codex"
    HOOKS_FILE="$CODEX_DIR/hooks.json"
    if [[ -e "$HOOKS_FILE" ]]; then
        echo "⚠️  已存在 $HOOKS_FILE；为避免覆盖，未自动写入 Codex Hook。"
        echo "   请将 README 中的 hooks 配置合并后再重试。"
    else
        echo "==> 配置 Codex Hook 到 $HOOKS_FILE"
        mkdir -p "$CODEX_DIR"
        cat > "$HOOKS_FILE" <<EOF
{
  "description": "TrafficLightController 的 Codex 生命周期状态灯。",
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$BIN_DIR/trafficlight-codex-hook"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "$BIN_DIR/trafficlight-codex-hook", "async": true}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "$BIN_DIR/trafficlight-codex-hook"}]}],
    "Interrupt": [{"hooks": [{"type": "command", "command": "$BIN_DIR/trafficlight-codex-hook"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "$BIN_DIR/trafficlight-codex-hook"}]}]
  }
}
EOF
    fi
fi

# 6. 合并 WorkBuddy Hook
if [[ " $* " == *" --with-workbuddy-hooks "* ]]; then
    WORKBUDDY_SETTINGS="$HOME/.workbuddy/settings.json"
    echo "==> 合并 WorkBuddy Hook 到 $WORKBUDDY_SETTINGS"
    python3 "$ROOT/scripts/install-workbuddy-hooks.py" "$WORKBUDDY_SETTINGS" "$BIN_DIR/trafficlight-workbuddy-hook"
fi

# 7. 启动
if [[ " $* " == *" --launch "* ]]; then
    echo "==> 启动 TrafficLight"
    open -b com.kzaven.trafficlight 2>/dev/null || open "$APP_DIR/$APP_NAME"
fi

echo ""
echo "✅ 安装完成"
echo "   App:   $APP_DIR/$APP_NAME"
echo "   CLI:   $BIN_DIR/trafficlight"
echo "   验证:  trafficlight status"
