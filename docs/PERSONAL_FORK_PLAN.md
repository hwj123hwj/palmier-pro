# Palmier Pro 个人版改造计划

把上游 palmier-io/palmier-pro（半商业开源，GPLv3）改造成纯个人本地使用的视频编辑器。

## 总体决策

1. **不自建后端服务器。** 上游的 Convex 后端函数（任务提交、模型目录、计费、agent 流式接口）全部闭源，仓库里只有客户端调用；自己部署 Convex 得到的只是空数据库，所有服务端逻辑仍要从零写。单用户场景下这层没有价值。
2. **生成能力走 app 内直连第三方 API**（Phase 2）：Seedance/Kling/Veo/Nano Banana 等模型在 fal.ai / Replicate 等聚合平台均有，一张 API key、统一的 submit/poll 模式，参考素材用 data-URI 上传，不需要自建存储。
3. **应用内 Agent 聊天保留 BYOK 路径**（自有 Anthropic/OpenAI key 直连），删除托管计费路径。
4. **转写只用本地**：Apple Speech + `BundledSpeech`（MLX）；云端转写删除。以后不够再评估本地 Whisper。
5. **GPLv3**：纯自用零义务；如日后分发二进制，需同时提供修改后源码。

## Phase 1 — 剥离商业层，得到纯本地编辑器

基线：当前 HEAD（上游 d2add80）。Phase 2 需要恢复供应商无关代码时，用 `git show HEAD:<path>` 取回。

### 删除

| 范围 | 内容 |
|---|---|
| 依赖 | Package.swift 中的 clerk-ios、convex-swift、clerk-convex-swift、Sentry/PostHog（遥测 trait）、Sparkle；`ProductionTelemetry` trait |
| `Account/` | Clerk + Google 登录、订阅档位、积分、Stripe 充值、账户 UI |
| `Backend/` | Convex 配置、`BackendStorage` 分段上传、`BackendError` |
| `Telemetry/` | Sentry + PostHog 启动与事件（默认构建本就未编译，连门面一起删） |
| `Generation/` | 整条生成链路（目录、提交、目录、编辑提交、UI）。MCP/Agent 的 generate 工具同步移除 |
| 云转写 | `CloudTranscription`、`TranscriptionBackend`；本地转写保留 |
| 托管聊天 | `PalmierClient`（Convex `/v1/agent/stream`）、`AgentRouting` 的积分/付费档路由 |
| 更新 | Sparkle：`Updater`、`UpdateBadgeView`、`UpdateOverlay`、Info.plist SU* keys、appcast 相关 |
| 反馈 | `FeedbackView`、`ToolExecutor+Feedback`（上报到上游 Convex） |
| 设置页 | `AccountPane`、`PrivacyPane`（遥测开关随遥测一起消失） |

### 保留

- 编辑器内核：Project / Timeline / Editor / Export / Compositing / Audio 本地分析
- 本地转写 + `BundledSpeech`（MLX 语音增强、说话人识别）
- 本地模型：BeatThis 节拍检测、siglip2 视觉搜索（HuggingFace 下载，无需账号）
- MCP server（`http://127.0.0.1:19789/mcp`）与 BYOK 应用内聊天（`KeychainStore` 存 key）
- `palmier-skills` 技能目录拉取（可通过 `PALMIER_SKILLS_BASE` 指向自有源）

### 打包

`bundle.sh` 已精简为一条命令出 ad-hoc 签名的 `.app`：删除 `.env` 强制检查、遥测 key 注入、`--sign`/`--dist`/公证/DMG 分支、Sparkle 框架嵌入、entitlements（keychain group 只为 Clerk 会话共享而设）。本机构建产物无 quarantine 属性，Gatekeeper 不拦，拖进 `/Applications` 即用。

### 本机构建环境适配（无 Xcode，仅 Command Line Tools）

这台机器没有 Xcode（只有 CLT 26.4 + Swift 6.3.1），且公司环境不允许注册 Apple ID。为此做了如下适配：

1. **Metal 内核**：CLT 没有 `metal` 编译器。`MetalCIKernelPlugin` 在工具链可用时产出编译后的 metallib 字节，否则原样拷贝内核源码，统一命名为 `.cikernel`；`CIKernelLoader` 按 `MTLB` 魔数分派。内核源码已改为 `[[stitchable]]`（去掉 `extern "C"`）——这是运行时编译（`CIKernel.kernels(withMetalString:)`）的硬性要求，编译期 `-fcikernel` 路径同样兼容。装了 Xcode 后自动回到编译路径。
2. **lottie-ios 锁定 4.5.2**：4.6.x 在 macOS 26 SDK 下使用 `@Entry` 宏，其插件（SwiftUIMacros）只随 Xcode 发布，CLT 编不过。4.5.2 用经典 EnvironmentKey 模式，本项目用到的 Lottie API 在两个版本都有。
3. **`Testing` 模块**：CLT 自带的 swift-testing framework 不在默认搜索路径，测试 target 加了 `-F` 和 rpath 指向 CLT 的框架目录。
4. **`#Preview` 宏**：插件同样只随 Xcode 发布，四个文件里的 `#Preview` 块已删除（纯开发预览，无运行时作用）。
5. **测试执行经 swiftly 解锁**：CLT 自带的 swift-testing 运行时会静默发现 0 个测试（不可用）。已安装 [swiftly](https://github.com/swiftlang/swiftly)（Apple 官方开源工具链管理器，`installer -target CurrentUserHomeDirectory` 装到用户目录，无需 Apple ID/sudo），工具链 Swift 6.3.3 位于 `~/.swiftly`，`.zshrc` 已挂载其 env。仓库 `.swift-version` 固定为 `Swift 6.3.3`。

### 验证标准

- `swift build` 通过 ✅
- `swift build --traits BundledSpeech` 通过 ✅
- `swift test` 全量通过 ✅（1524 tests / 238 suites，swiftly 工具链执行）
- 三个依赖系统语言的测试已改为 locale 无关（通知文案、本地化包、菜单快捷键）
- 手动 UI 清单：见执行报告

## Phase 2 — 生成能力重建（已完成）

生成不走上游后端，两条通道并存（`GenerationChannel`）：

1. **浏览器通道（默认，零 API 成本）**：ego-browser 驱动网页会话，见
   `docs/BROWSER_GENERATION.md`。图片 = ChatGPT 网页（支持参考图）、视频 = Gemini Veo
   （Bilal profile，支持图生视频首帧）、音乐 = Gemini Lyria。Generate 面板三档 +
   `generate_video/generate_image/generate_audio` Agent 工具都已接入。
2. **fal.ai 通道（备用，付费）**：Kling t2v/i2v、Nano Banana Pro，key 存 Keychain
   （Settings → Agent）。

## 暂不做 / 可选后续

- 品牌与 bundle ID 重命名（涉及 Keychain/UserDefaults 迁移，收益纯观感）
- README / 徽章 / 社区链接清理
- Developer ID 签名 + 公证（需要 $99/年 开发者账号，仅在向其他 Mac 浏览器分发时有意义）
- 本地 Whisper 接入
- `enhanceDraft`（提示词润色）改走 BYOK Anthropic
- 直连厂商 adapter（火山 Seedance、Kling 官方 JWT、Gemini API、OpenAI）——想去掉
  fal.ai 聚合层时再做
