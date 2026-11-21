# CodeIsland JJ

CodeIsland 在 MacBook 刘海处显示 AI 编码助手的会话状态。展开面板可以查看进度、处理审批，或点击卡片回到对应会话。

本仓库从 [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland) 的 `v1.0.41` 分叉，主要改进 macOS 上的额度显示、Codex 桌面对话和多桌面体验。项目由原作者 wxtsky 和上游贡献者开发。

## 本版改动

- **Codex 额度** — 在会话列表底部显示 5 小时和每周已用额度及重置时间。数据来自 Codex 的本地记录。
- **Cursor 和 Grok 用量** — Cursor 显示当前账期的套餐用量，Grok 显示每周额度。开启后使用本机已有登录向各自服务查询。
- **用量设置** — 把 Claude、Codex、Cursor 和 Grok 的用量选项集中到「用量与额度」。面板底部按当前会话所属的助手显示相应信息。
- **Codex 桌面对话** — 识别由 ChatGPT 辅助进程启动的 Codex，合并此前误识别的重复卡片。点击桌面卡片可直接打开对应对话。
- **Codex 审批** — 将 Codex 送来的权限请求显示在灵动岛，可在卡片上处理。
- **Antigravity 模型显示** — 在会话卡片中显示模型名称，并在有数据时单独显示推理强度。
- **macOS 多桌面** — 修复切换桌面后灵动岛可能消失的问题，并在调度中心（Mission Control）中隐藏面板。

## 从源码构建

macOS 构建脚本面向 Apple Silicon。请先安装 Xcode。

```bash
git clone https://github.com/xujianjun95/CodeIsland.git
cd CodeIsland
./build.sh
open .build/release/CodeIsland.app
```

## 许可证

本项目沿用 [MIT 许可证](LICENSE)。
