# 浏览器生成（免 API）

用 ego-browser 复用 ChatGPT / Gemini 网页登录态生图、生视频、生音乐：不申请 API key、
不产生 API 费用，只消耗订阅额度。图片/视频链路 2026-08-16 实测跑通，参考图与图生视频
2026-08-17 实测跑通。

## 一键使用

```bash
scripts/generate-image-browser.sh "提示词" [输出路径.png] [--reference-image 本地图]...
scripts/generate-video-browser.sh "提示词" [输出.mp4] [profile 名，默认 Bilal] [--source-image 本地图]
scripts/generate-music-browser.sh "提示词" [输出.mp4] [profile 名，默认 Bilal]
```

默认输出到 `~/Downloads/`。参数经 `/tmp/palmier-*-bridge.txt` 桥接文件传给 ego 的
node 运行时（ego 不透传环境变量），桥内全部 base64——提示词可以含换行。

前提：ego-browser CLI 已安装、对应网站已登录（任务空间继承登录态）。

## App 内使用（已集成）

Generate 面板（⌘G）三档：视频 / 图片 / 音乐。浏览器通道模型：

- **Gemini Veo (Browser)** — 视频；可选 Start Frame（图生视频，上传为会话首帧）
- **GPT Image (Browser)** — 图片；可挂最多 3 张 References（上传进 composer）
- **Gemini Music (Browser)** — 音乐；无参数

Agent / MCP 工具：`list_models`（type 含 `audio`）、`generate_video`（`startFrameMediaRef`
在 Veo 上可选传）、`generate_image`（`referenceImageMediaRefs` 全通道生效）、`generate_audio`。
源图/参考图按资产在项目包里的绝对路径传给脚本，脚本再 `uploadFile` 进网页。

## 实测链路（脚本内部做的事）

1. `useOrCreateTaskSpace('palmier web generation')` — 固定任务空间，跨次复用一个 tab
2. 打开 `chatgpt.com/` 首页（新会话）
3. 有参考图时先 `uploadFile('input[type="file"]', path)` 逐张挂进 composer，并快照
   当时页面所有 `img` 的 src（附件会在发出的消息里回显，结果检测要排除）
4. `fillInput('#prompt-textarea', 提示词)` + 等待 `button[data-testid="send-button"]`
   可用后点击（附件上传期间按钮禁用，脚本轮询最长 40 秒）
5. 每 5 秒轮询 `main img`，出现 `naturalWidth > 256`、非头像/Logo、且 src 不在快照里的
   **新**图即完成；多条命中取 DOM 序最后一个（结果渲染在最底部）
6. 页面内 `fetch(签名URL)` → FileReader 转 base64 → Node 侧写盘 → 校验 PNG 魔数

## 三个实测踩过的坑（改脚本前必读）

1. **ego-browser 不透传环境变量**：`PROMPT=x ego-browser nodejs` 里 `process.env.PROMPT`
   是 undefined，且带 undefined 参数的调用报 "Invalid parameters"。传参用固定桥接文件
   `/tmp/palmier-gen-bridge.txt`（并发运行会撞，个人用无所谓）
2. **二进制不过 CDP 边界**：`browserFetch` 返回的裸二进制字符串有替换字符，落盘文件损坏。
   必须在页面内转 base64（自带 cookie），Node 侧再 `Buffer.from(b64, 'base64')`
3. **heredoc 引号**：脚本内 JS 有模板字符串和反斜杠，heredoc 必须 `<<'EOF'`（单引号），
   否则 bash 展开会把代码搅碎。所以传参只能走坑 1 的文件桥

另外每个 heredoc 是独立 Node 进程，开头必须 `useOrCreateTaskSpace(...)` 先选空间。

## 生命周期：用完即关，不积窗口

两个脚本成功后自动 `completeTaskSpace(keep: false)`——空间及其标签页/窗口随即关闭，
不会越积越多。登录态存在 Chromium profile 里而非任务空间，关掉无损失，下次运行只多
几秒页面加载。若某次运行中途失败留下空间，下次运行会复用或重建；手动清理：
`ego-browser nodejs` 里 `ego.deleteSpaces({ ids: [...] })`。

## 边界与风险

- **频率**：网页自动化属 OpenAI / Google ToS 灰区，个人低频没事，高频轰炸有账号风控风险
- **脆弱性**：`#prompt-textarea` / `send-button` / `main img` / Gemini 的
  `rich-textarea .ql-editor` / `Upload & tools` 是当前 UI 的选择器，网站改版需跟着更新
  （都在脚本里，一处可改）
- 单张图全程约 1 分钟（含浏览器就绪）

## 视频生成（Gemini / Veo，走 Bilal 账号）

```bash
scripts/generate-video-browser.sh "提示词（建议以 Generate a video: 开头）" [输出.mp4] [profile 名，默认 Bilal] [--source-image 本地图]
```

链路（2026-08-16 实测，单条约 1 分钟生成 + 下载；i2v 2026-08-17 实测）：

1. 任务空间绑定 **Bilal profile**（见下节），打开 `gemini.google.com/app`
2. `--source-image` 时：点击 `button[aria-label="Upload & tools"]` 打开上传菜单（composer
   的 `input[type="file"]` 只在菜单打开后才挂载），`waitForElement` 等挂载后
   `uploadFile` 塞图。该 input 的 accept 列表只有文档扩展名，但 CDP 设置文件不受
   accept 过滤，图片正常上传（实测出现 "Uploading image" toast + 附件芯片）
3. `fillInput('rich-textarea .ql-editor', 提示词)`——Gemini 的 composer 是 Quill
   rich-textarea，选择器 `rich-textarea .ql-editor`
4. 等待 `button.send-button`（或 `button[aria-label*="Send"]`）可用后点击——附件上传
   期间禁用
5. 每 10 秒轮询 `main video` 元素（最长 6 分钟），出现即生成完成
6. `video.src` 是 `contribution.usercontent.google.com` 签名下载链——**必须页面内
   fetch**（要 Google cookie），base64 落盘，校验 MP4 `ftyp` 魔数

## 音乐生成（Gemini / Lyria，Bilal 账号）

```bash
scripts/generate-music-browser.sh "Generate music: 描述风格/情绪/时长" [输出.mp4]
```

与视频管线同构（Gemini 把音频渲染在 `<video>` 元素里，AAC-in-mp4）。注意时长由
网页模型自定（实测固定 ~30 秒，提示词写 15s 也是 30s）。下载一处不同：音频 URL
偶尔很慢，会超过单次 `js()` 求值超时——脚本用"页面内启动 fetch、结果存
`window.__palmierDL`、2 秒轮询取回"的模式绕开（generate-music-browser.sh 里的
实现）。播放器上的 "Download track" 按钮对 CDP 点击无响应，直接 fetch 元素 src。

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
