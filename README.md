# CodexNotch

一个在 MacBook 刘海区域展示 Codex 任务、用量和连接状态的轻量 macOS 应用。

[产品主页](https://codexnotch.pages.dev/) · [English](https://codexnotch.pages.dev/en/) · [下载安装](https://github.com/VibeDough/CodexNotch/releases/latest) · [产品文档](docs/PRODUCT.md)

当前版本支持：

- 从本机 Codex 会话记录读取运行、分析、等待确认和完成状态
- 多任务常驻摘要及展开查看
- 点击任务或确认提示返回对应 Codex 对话
- 今日 Token 消耗、剩余用量、重置时间和 Codex 版本展示
- 连接、断开与重连状态提示
- MacBook 刘海屏及无刘海显示器适配
- 文件、网址和文字拖入后生成“在 Codex 新建对话”按钮
- 跟随系统语言，并可在设置中手动切换中文或 English

## 构建应用

需要 macOS 14 或更高版本以及 Swift 6：

```sh
cd CodexPetNotch
sh build-app.sh
open "dist/CodexNotch.app"
```

应用只在本机读取 `~/.codex/sessions/` 中的会话状态，不上传会话内容或用量数据。

拖入动作会生成包含文件路径、网页地址或文字原文的分析指令。点击刘海中的“在 Codex 新建对话”按钮后，会打开 Codex 新对话并带入该指令。

## 开源与品牌

CodexNotch 源代码采用 [GNU GPL v3.0](LICENSE) 开源。你可以使用、研究、修改和分发代码；分发修改版本时，需要遵守 GPLv3 并提供对应源代码。

`CodexNotch` 名称、官方图标和 Logo 不属于 GPL 授权范围。公开分发的 Fork 应使用不同的产品名称和图标，并明确说明不是 49Labs 官方版本。详见 [品牌政策](TRADEMARKS.md)。

欢迎通过 Fork 和 Pull Request 参与，参见 [贡献指南](CONTRIBUTING.md)。
