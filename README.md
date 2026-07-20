# 49agent Notch

一个在 MacBook 刘海区域展示 Codex 任务、用量和连接状态的轻量 macOS 应用。

[产品主页](https://vibedough.github.io/49agent-notch/) · [English](https://vibedough.github.io/49agent-notch/en/) · [下载安装](https://github.com/VibeDough/49agent-notch/releases/latest) · [产品文档](docs/PRODUCT.md)

当前版本支持：

- 从本机 Codex 会话记录读取运行、分析、等待确认和完成状态
- 多任务常驻摘要及展开查看
- 点击任务或确认提示返回对应 Codex 对话
- 今日 Token 消耗、剩余用量、重置时间和 Codex 版本展示
- 连接、断开与重连状态提示
- MacBook 刘海屏及无刘海显示器适配
- 文件、网址和文字拖入后生成“在 Codex 新建对话”按钮

## 构建应用

需要 macOS 14 或更高版本以及 Swift 6：

```sh
cd CodexPetNotch
sh build-app.sh
open "dist/49agent Notch.app"
```

应用只在本机读取 `~/.codex/sessions/` 中的会话状态，不上传会话内容或用量数据。

拖入动作会生成包含文件路径、网页地址或文字原文的分析指令。点击刘海中的“在 Codex 新建对话”按钮后，会打开 Codex 新对话并带入该指令。

## 许可

本项目采用双许可模式：

- 个人与其他非商业用途遵循 [PolyForm Noncommercial 1.0.0](LICENSE.md)，可以在条款允许的范围内使用、修改和分发。
- 商业使用、付费集成、商业分发或基于本项目开发商业产品，需要获得 49Labs 的单独书面授权。参见 [商业许可说明](COMMERCIAL_LICENSE.md)。

这是一款源码可见（source-available）软件，不是 OSI 定义的开源软件。保留所有版权与许可声明。
