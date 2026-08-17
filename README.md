# Palmier Pro（个人本地版）

上游 [palmier-io/palmier-pro](https://github.com/palmier-io/palmier-pro) 的个人改造版：
剥离账号 / 订阅 / 积分 / 云端转写 / 遥测 / 自动更新等商业层，生成能力改为
浏览器会话（零 API 成本）+ fal.ai（备用）两条通道，纯本地单机使用。

macOS 26 (Tahoe) / Apple Silicon / Swift 6.2 + SwiftUI + AppKit + AVFoundation。

<img src="./assets/palmier-ui.png" alt="Palmier Pro UI" width="900" />

## 功能

- **完整时间线编辑器**：多轨视频/音频/图片/文本/字幕、多机位、关键帧、调色、特效、导出
- **本地转写**：Apple Speech + `BundledSpeech`（MLX 增强、说话人识别），无云端依赖
- **本地模型**：BeatThis 节拍检测、siglip2 视觉搜索（HuggingFace 下载，无需账号）
- **AI 生成**（Generate 面板 + Agent/MCP 工具同一套链路）：
  - 图片：ChatGPT 网页（支持参考图）——`docs/BROWSER_GENERATION.md`
  - 视频：Gemini Veo（Bilal 账号 profile，支持图生视频首帧）
  - 音乐：Gemini Lyria（约 30 秒曲目）
  - 备用 fal.ai：Kling t2v/i2v、Nano Banana Pro（key 存 Keychain）
- **Agent 双入口**：应用内 BYOK 聊天（自有 Anthropic/OpenAI key）、MCP server
  （`http://127.0.0.1:19789/mcp`，app 打开时可用）

## 构建（无 Xcode，CLT + swiftly）

这台机器只有 Command Line Tools，无 Apple ID 登录。工具链经
[swiftly](https://github.com/swiftlang/swiftly) 管理（`~/.swiftly`，仓库
`.swift-version` 固定 Swift 6.3.3）。CLT 环境适配见
`docs/PERSONAL_FORK_PLAN.md`（Metal 内核 stitchable、lottie 4.5.2、Testing 路径等）。

```bash
swift build                 # 日常开发
swift build --traits BundledSpeech   # 涉及 MLX/语音/转写资源时
swift test                  # 测试（经 swiftly 工具链执行）
./scripts/bundle.sh         # 出 ad-hoc 签名的 .app 到 .build/，cp -R 到 /Applications
```

## MCP 接入

```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

Cursor / Claude Desktop：app 内 `Help` → `MCP Instructions` 一键安装。

## 文档

| 文档 | 内容 |
|---|---|
| `docs/PERSONAL_FORK_PLAN.md` | 改造总计划：决策、Phase 1 删除范围、CLT 环境适配 |
| `docs/BROWSER_GENERATION.md` | 浏览器生成管线：脚本用法、选择器、踩坑记录、ego 多账号 |
| `docs/Localization.md` | 本地化工作流（sync 脚本、语言包规范） |
| `AGENTS.md` | 代码架构约定、并发/文件 IO/测试规范 |

## 上游同步

```bash
git fetch upstream
git cherry-pick <upstream-commit>   # 冲突时上游删除的文件按 git rm 处理
swift build && swift test           # 死引用安全网
```

## 许可

GPLv3（见 [LICENSE](LICENSE)）。基于 Palmier, Inc. 的开源版本改造，自用零义务；
如日后分发二进制，需同时提供修改后源码。
