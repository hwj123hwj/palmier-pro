# 浏览器生成（免 API）

用 ego-browser 复用 ChatGPT 网页登录态生图：不申请 API key、不产生 API 费用，
只消耗 ChatGPT 订阅额度。2026-08-16 实测跑通。

## 一键使用

```bash
scripts/generate-image-browser.sh "提示词" [输出路径.png]
```

默认输出到 `~/Downloads/palmier-gen-<时间>.png`。产物为合法 PNG，可直接拖进
Palmier Pro 媒体面板。

前提：ego-browser CLI 已安装、ChatGPT 已在浏览器里登录（任务空间继承登录态）。

## 实测链路（脚本内部做的事）

1. `useOrCreateTaskSpace('palmier web generation')` — 固定任务空间，跨次复用一个 tab
2. 打开 `chatgpt.com/` 首页（新会话）
3. `fillInput('#prompt-textarea', 提示词)` + 点击 `button[data-testid="send-button"]`
4. 每 5 秒轮询 `main img`，出现 `naturalWidth > 256` 且非头像/Logo 的图即完成（约 15 秒）
5. 页面内 `fetch(签名URL)` → FileReader 转 base64 → Node 侧写盘 → 校验 PNG 魔数

## 三个实测踩过的坑（改脚本前必读）

1. **ego-browser 不透传环境变量**：`PROMPT=x ego-browser nodejs` 里 `process.env.PROMPT`
   是 undefined，且带 undefined 参数的调用报 "Invalid parameters"。传参用固定桥接文件
   `/tmp/palmier-gen-bridge.txt`（并发运行会撞，个人用无所谓）
2. **二进制不过 CDP 边界**：`browserFetch` 返回的裸二进制字符串有替换字符，落盘文件损坏。
   必须在页面内转 base64（自带 cookie），Node 侧再 `Buffer.from(b64, 'base64')`
3. **heredoc 引号**：脚本内 JS 有模板字符串和反斜杠，heredoc 必须 `<<'EOF'`（单引号），
   否则 bash 展开会把代码搅碎。所以传参只能走坑 1 的文件桥

另外每个 heredoc 是独立 Node 进程，开头必须 `useOrCreateTaskSpace(...)` 先选空间。

## 边界与风险

- **频率**：网页自动化属 OpenAI ToS 灰区，个人低频没事，高频轰炸有账号风控风险
- **脆弱性**：`#prompt-textarea` / `send-button` / `main img` 是当前 UI 的选择器，
  ChatGPT 改版需跟着更新（都在脚本里，一处可改）
- **仅图片**：视频不在此链路（另见下节）
- 单张全程约 1 分钟（含浏览器就绪）

## 规划中的集成

Palmier Pro 侧可加 `BrowserChatGPTProvider` adapter：`GenerationProvider` 协议的
实现之一，`submit/poll/result` 通过 `Process` 调 `ego-browser nodejs` 驱动网页，
零 key、走订阅。与 fal / 直连厂商在目录里并存可选。

## 视频生成（Gemini / Veo，走 Bilal 账号）

```bash
scripts/generate-video-browser.sh "提示词（建议以 Generate a video: 开头）" [输出.mp4] [profile 名，默认 Bilal]
```

链路（2026-08-16 实测，单条约 1 分钟生成 + 下载）：

1. 任务空间绑定 **Bilal profile**（见下节），打开 `gemini.google.com/app`
2. `fillInput('rich-textarea .ql-editor', 提示词)`——Gemini 的 composer 是 Quill
   rich-textarea，选择器 `rich-textarea .ql-editor`
3. 点击 `button.send-button`（或 `button[aria-label*="Send"]`）
4. 每 10 秒轮询 `main video` 元素（最长 6 分钟），出现即生成完成
5. `video.src` 是 `contribution.usercontent.google.com` 签名下载链——**必须页面内
   fetch**（要 Google cookie），base64 落盘，校验 MP4 `ftyp` 魔数

## ego-lite 多账号 = 多 Chromium profile

- `ego.listProfiles()` 列出：`Default`（威健）、`huang`（weijianzuibang）、`Bilal`
- **任务空间在创建时绑定 profile**：`ego.createTaskSpace(名字, profileId)`；已存在的
  空间不能换 profile。日常复用 `useOrCreateTaskSpace(id)` 即可
- 空间里的标签页跑在绑定 profile 的登录态下——图片脚本用默认空间（ChatGPT，主账号），
  视频脚本用 Bilal 空间（Gemini），互不干扰
- 同一 Google profile 内多账号也可用 `?authuser=N` 切换，但 Bilal 是独立 profile，
  不走这条路

## 风险（视频同图片）

低频个人用没事；高频有 Google 风控风险；Gemini 改版需更新选择器（都在脚本里）。
