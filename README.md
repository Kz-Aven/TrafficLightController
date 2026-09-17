# 🚦 桌宠红绿灯 · Desktop Traffic Pet

> 不必盯着转圈，也不用猜 Agent 是否还在工作。看一眼红绿灯，就知道它正在忙、已经完成，还是等待下一条任务。

TrafficLightController 是一个运行在 macOS 菜单栏的本地桌宠红绿灯。它由 Agent 的真实生命周期事件驱动，支持 Codex、WorkBuddy、Claude Code、Hermes、MCP Agent 与 Tigerose macOS App。

关键词：macOS AI Agent 桌宠红绿灯、Agent status light、Codex Hook、WorkBuddy Hook、MCP server、local AI agent monitor。

## 状态一览

| 灯色 | Agent 状态 | 说明 |
| --- | --- | --- |
| 🔴 红灯 | 空闲 | 没有运行任务，等待下一条指令 |
| 🟠橙灯闪烁 | 工作中 | 至少有一个 Agent 任务正在运行 |
| 🟢绿灯 | 已完成 | 最后一个任务成功结束，结果等待查看 |

绿灯会在短暂展示后自动回到红灯；新任务开始时，无论此前是否为绿灯，都会立即转为橙灯。

## 快速开始

获取项目

```
git clone https://github.com/Kz-Aven/TrafficLightController.git && cd TrafficLightController
```

在项目根目录执行：

```bash
bash scripts/build_app.sh
bash scripts/install.sh --with-skill --with-codex-hooks --with-workbuddy-hooks --launch
```

安装完成后会得到：

| 命令 | 用途 |
| --- | --- |
| `trafficlight` | 手动发送任务生命周期事件或查看状态 |
| `trafficlight-run` | 包装任意 CLI 子进程，自动维护状态 |
| `trafficlight-mcp` | 为 MCP Agent 提供状态控制工具 |
| `trafficlight-codex-hook` | Codex Desktop / CLI 的原生 Hook 运行器 |
| `trafficlight-workbuddy-hook` | WorkBuddy macOS App 的原生 Hook 运行器 |

验证 App 是否已启动：

```bash
trafficlight status
```

### 交给 Agent 安装

打开本项目后，可以复制对应提示词并粘贴给你的 Agent，由它完成本地安装与验证。

**给 Codex：**

```text
请先执行：
git clone https://github.com/Kz-Aven/TrafficLightController.git && cd TrafficLightController

然后安装并配置 TrafficLightController：构建 App，安装 trafficlight、trafficlight-run、trafficlight-mcp 和 Skill，配置 Codex 原生 Hook，启动 TrafficLight App，并用 trafficlight status 验证。

不要覆盖已有 ~/.codex/hooks.json 或其他 Codex 配置：如果该文件已存在，请将 TrafficLightController 的 UserPromptSubmit、PostToolUse、Stop、Interrupt、SessionEnd Hook 合并进去。完成后告诉我需要在 Codex“设置 → 钩子”中审查并信任该 Hook。
```

**给 WorkBuddy：**

```text
请先执行：
git clone https://github.com/Kz-Aven/TrafficLightController.git && cd TrafficLightController

然后安装并配置 TrafficLightController：构建 App，安装 trafficlight、trafficlight-run、trafficlight-mcp 和 Skill，把 WorkBuddy 原生 Hook 合并到 ~/.workbuddy/settings.json，启动 TrafficLight App，并用 trafficlight status 验证。

不要覆盖 ~/.workbuddy/settings.json 中已有的插件、Hook 或其他设置。WorkBuddy 的配置目录是 ~/.workbuddy，不是 ~/.codebuddy。若 WorkBuddy 正在运行，请使用安全方式重启或提醒我重启，使新 Hook 生效。
```

## 选择接入方式

优先使用宿主提供的原生 Hook 或运行时 Adapter。它们能覆盖真实回合生命周期，不依赖模型自行记得调用命令。

| 环境 | 推荐方式 | 自动化程度 |
| --- | --- | --- |
| Codex Desktop / CLI | 原生 Hook | 完整回合生命周期 |
| WorkBuddy macOS App | 原生 Hook | 完整回合生命周期 |
| Tigerose macOS App | 运行时 Adapter | 完整回合生命周期 |
| Claude Code / Hermes 等 CLI | `trafficlight-run` | 子进程生命周期 |
| 支持 MCP 的 Agent | `trafficlight-mcp` | 由 Agent 调用工具 |
| 不支持上述能力的 Agent | `trafficlight` CLI | 手动接入生命周期 |

## Codex 原生 Hook

Codex 是首选接入方式。安装命令中的 `--with-codex-hooks` 会在没有既有配置时创建 `~/.codex/hooks.json`。首次加载后，在 Codex 的“设置 → 钩子”中审查并信任该 Hook。

如果已有 `~/.codex/hooks.json`，安装器不会覆盖它。请把以下五个事件合并到已有的 `hooks` 对象中：

<details>
<summary>展开 Codex hooks.json 配置</summary>

```json
{
  "description": "TrafficLightController 的 Codex 生命周期桌宠红绿灯。",
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "trafficlight-codex-hook" }] }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "trafficlight-codex-hook", "async": true }
        ]
      }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "trafficlight-codex-hook" }] }
    ],
    "Interrupt": [
      { "hooks": [{ "type": "command", "command": "trafficlight-codex-hook" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "trafficlight-codex-hook" }] }
    ]
  }
}
```

</details>

用户提交消息时转橙，并启动独立保活器每 20 秒刷新心跳，因此网络重连、长时间推理或无工具调用不会让任务提前变红。工具完成后也会立即刷新心跳；回合正常结束时转绿；中断或会话结束时仅结束关联任务。只有 `PostToolUse` 异步执行，以避免增加工具完成后的等待时间。

## WorkBuddy 原生 Hook

WorkBuddy Mac App 使用独立的用户配置目录 `~/.workbuddy/`，不是 CodeBuddy CLI 的 `~/.codebuddy/`。运行以下命令会以幂等方式把五个生命周期事件合并到 `~/.workbuddy/settings.json`，不会覆盖已有插件和 Hook：

```bash
bash scripts/install.sh --with-workbuddy-hooks
```

重启 WorkBuddy 后，新 Agent 回合会自动调用 `trafficlight-workbuddy-hook`：开始时橙灯、工具调用后保活、成功结束时绿灯、中断或会话结束时红灯。

## CLI 与运行包装器

CLI 适合宿主 Adapter、脚本或不支持 Hook 的 Agent：

```bash
trafficlight start --id task-1 --name "分析代码"
trafficlight heartbeat --id task-1
trafficlight done --id task-1 --result success
trafficlight idle --reason "等待用户输入"
```

`trafficlight-run` 适合包装一个完整命令。它自动发送 `start`、每 20 秒发送 `heartbeat`，并根据子进程退出码发送成功或失败结果：

```bash
trafficlight-run --name "Claude Code" -- claude
trafficlight-run --name "Codex" -- codex exec "修复测试"
```

## MCP

为 MCP 客户端增加以下配置：

```json
{
  "mcpServers": {
    "trafficlight": {
      "command": "trafficlight-mcp"
    }
  }
}
```

MCP 提供 `start_task`、`complete_task`、`idle` 与 `status`。它适合处理 Agent 沙箱无法直接访问本地 Unix socket 的场景；但 MCP 不会自行获知 Agent 的开始或结束，因此自动状态仍优先使用 Hook、运行包装器或宿主 Adapter。

## 工作原理

```text
start  -> 橙灯闪烁
heartbeat -> 保持橙灯
done(success) -> 无其他任务时转绿
idle / done(fail) / 超时 -> 红灯
```

多个任务可使用不同 `--id` 并行运行。只要仍有一个任务在运行，桌宠红绿灯就保持橙色；最后一个任务成功完成后才会转绿。

## 开发验证

```bash
swift test --package-path app
python3 mcp/test_trafficlight_mcp.py
python3 scripts/test_trafficlight_codex_hook.py
```

## 许可证

[MIT License](LICENSE)
