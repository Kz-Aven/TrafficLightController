---
name: traffic-light-controller
description: 通过 trafficlight CLI 控制 Mac 桌面红绿灯，红色表示空闲、橙色表示工作中、绿色表示任务完成。当 Agent 需要可视化当前状态，或用户要求控制红绿灯时使用。Agent 应调用 start、heartbeat、done、idle、ack 等任务生命周期事件，而不是直接设置颜色。
---

# TrafficLightController

## 概述

通过 `trafficlight` CLI 控制 Mac 桌面红绿灯，向用户直观展示 Agent 当前状态：

- **红色**：空闲，等待新任务
- **橙色**：工作中，有任务正在执行
- **绿色**：任务刚完成，结果待查看

Agent 不应直接设置红/绿/橙，而应发送**任务生命周期事件**。红绿灯 App 内部根据事件自动计算显示状态。

---

## 前置条件

- Mac 桌面已安装并运行 `TrafficLight` App。
- 终端可执行 `trafficlight` 命令。
- Agent 能执行 shell 命令。

---

## CLI 命令参考

所有命令返回 JSON，格式如下：

```json
{
  "state": "red | orange | green",
  "running_tasks": 0,
  "last_completion": { "id": "task-1", "name": "总结文档", "time": "..." },
  "message": "..."
}
```

### 1. `trafficlight start`

开始一个新任务，使红绿灯进入橙色。

```bash
trafficlight start --id <任务ID> --name "<任务名称>"
```

- `--id`：唯一任务 ID，建议使用 UUID 或时间戳。
- `--name`：任务简短描述，用于显示。

**调用时机**：Agent 开始处理用户请求、调用工具、生成回复等任何需要用户等待的工作时。

---

### 2. `trafficlight heartbeat`

刷新任务心跳，保持橙色。防止因超时被误判为空闲。

```bash
trafficlight heartbeat --id <任务ID>
```

**调用时机**：任务运行超过 30 秒时，每隔 20～30 秒调用一次。

---

### 3. `trafficlight done`

标记任务完成。

```bash
trafficlight done --id <任务ID> --result success
trafficlight done --id <任务ID> --result fail
```

- `--result success`：成功完成。若没有其他运行中任务，红绿灯变绿。
- `--result fail`：任务失败。建议随后调用 `idle` 回到红色，或由 App 显示特殊错误状态。

**调用时机**：Agent 完成当前任务，并已生成最终回复或结果时。

---

### 4. `trafficlight idle`

显式进入空闲状态，等待新任务。

```bash
trafficlight idle --reason "<原因>"
```

- `--reason`：可选，说明为何空闲，如 `等待用户输入`、`任务失败`。

**调用时机**：
- 需要用户补充信息时。
- 任务失败后决定不再重试时。
- 用户长时间未回复，Agent 主动结束当前轮次时。

调用后红绿灯变红。

---

### 5. `trafficlight ack`

确认完成事件，结束绿色状态，回到红色空闲。

```bash
trafficlight ack --id <任务ID>
```

**调用时机**：
- 用户点击绿灯或确认结果后。
- Agent 开始处理用户下一条消息前，自动确认上一轮完成事件。

---

### 6. `trafficlight status`

查询当前红绿灯状态和任务列表。

```bash
trafficlight status
```

返回 JSON，Agent 可据此判断是否需要 `ack` 或 `idle`。

---

### 7. `trafficlight reset`

强制重置为空闲红色，清除所有运行任务和完成事件。

```bash
trafficlight reset
```

**调用时机**：异常恢复、用户手动要求重置时。

---

## Agent 调用规则

### 聊天型 Agent 标准流程

1. **用户发来消息**
   - 若上一轮有未确认的完成事件（绿灯），先调用：
     ```bash
     trafficlight ack --id <上一轮任务ID>
     ```
   - 然后开始新任务：
     ```bash
     trafficlight start --id <新任务ID> --name "处理用户请求"
     ```

2. **处理过程中**
   - 如需长时间思考或调用工具，保持任务运行。
   - 超过 30 秒时，调用：
     ```bash
     trafficlight heartbeat --id <任务ID>
     ```

3. **成功完成回复**
   - 调用：
     ```bash
     trafficlight done --id <任务ID> --result success
     ```
   - 红绿灯自动变绿，表示结果待查看。
   - 绿灯会保持 5～10 秒，或直到用户点击/发新消息，然后自动转红。

4. **需要用户输入**
   - 调用：
     ```bash
     trafficlight idle --reason "等待用户确认"
     ```
   - 红绿灯变红。

5. **任务失败**
   - 调用：
     ```bash
     trafficlight done --id <任务ID> --result fail
     trafficlight idle --reason "任务失败，等待指示"
     ```

### 多任务并行

- 每个任务使用独立 `--id`。
- 任意任务运行中，红绿灯保持橙色。
- 最后一个任务成功完成时，才变绿。
- 中途完成的任务不影响橙色，除非所有任务都结束。

### 超时与自动恢复

- 任务心跳超过 60 秒未刷新，App 会自动将其标记为丢失，并可能回到红色。
- 绿灯超过 10 秒未确认，自动转红。
- Agent 应始终在任务结束时调用 `done` 或 `idle`，避免状态悬挂。

---

## 示例：一次完整交互

用户：`帮我总结这篇文章。`

Agent 操作：

```bash
# 1. 开始任务
trafficlight start --id "task-001" --name "总结文章"

# 2. 处理中，假设耗时较长
trafficlight heartbeat --id "task-001"

# 3. 完成总结，成功
trafficlight done --id "task-001" --result success
# 红绿灯变绿

# 4. 用户看到绿色，点击确认（或 Agent 在下轮开始时自动 ack）
trafficlight ack --id "task-001"
# 红绿灯变红，空闲
```

用户：`再帮我翻译成英文。`

Agent 操作：

```bash
# 开始新任务前，自动确认上一轮完成
trafficlight ack --id "task-001"

trafficlight start --id "task-002" --name "翻译文章"
# 红绿灯变橙
...
trafficlight done --id "task-002" --result success
# 红绿灯变绿
```

---

## 注意事项

- 不要直接调用 `trafficlight set red/green/orange`，这类命令不应存在。
- 所有状态变化必须通过任务事件驱动。
- 任务 ID 必须唯一，建议使用 `uuidgen` 或时间戳。
- 若 CLI 返回错误，Agent 应记录日志并尝试 `trafficlight reset` 恢复。
- 此 Skill 只定义 Agent 侧行为，红绿灯 App 负责状态机、超时、多任务聚合和显示。

