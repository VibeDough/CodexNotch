# 49agent Notch

一个在 MacBook 刘海区域展示 Codex 任务、用量和连接状态的轻量 macOS 应用。

当前版本支持：

- 从本机 Codex 会话记录读取运行、分析、等待确认和完成状态
- 多任务常驻摘要及展开查看
- 点击任务或确认提示返回对应 Codex 对话
- 今日 Token 消耗、剩余用量、重置时间和 Codex 版本展示
- 连接、断开与重连状态提示
- MacBook 刘海屏及无刘海显示器适配
- 文件、网址和文字拖入后生成分析指令、复制到剪贴板并打开 Codex

## 构建应用

需要 macOS 14 或更高版本以及 Swift 6：

```sh
cd CodexPetNotch
sh build-app.sh
open "dist/49agent Notch.app"
```

应用只在本机读取 `~/.codex/sessions/` 中的会话状态，不上传会话内容或用量数据。

拖入动作会生成包含文件路径、网页地址或文字原文的分析指令，并复制到剪贴板；在自动打开的 Codex 中粘贴即可发送。
