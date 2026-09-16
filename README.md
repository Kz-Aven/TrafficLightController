# TrafficLightController
通过 trafficlight CLI 控制 Mac 桌面红绿灯，红色表示空闲、橙色表示工作中、绿色表示任务完成。当 Agent 需要可视化当前状态，或用户要求控制红绿灯时使用。Agent 应调用 start、heartbeat、done、idle、ack 等任务生命周期事件，而不是直接设置颜色。
