# VoiceInput 使用问题修复（2026-09-06）

本轮继续基于第一轮审查的开发副本，处理 Daily 润色、连接方式、快捷键、媒体暂停、词库自动学习。保留现有用户预设、API 配置和历史数据。

## 使用方式

Settings → Providers → Polish：

- **API / OpenRouter**：填写原来的 OpenRouter key 和模型。
- **API / Cursor SDK**：填写 Cursor Dashboard → API Keys 创建的 **User API key**，选择账户可用模型（例如 composer-2.5）。点击 **Install Cursor SDK** 安装官方 SDK，需要 Node.js 22.13+。SDK 使用与 IDE 相同的请求额度池；实际模型权限、额度和超额计费以 Cursor 账户为准。这里不使用 `/v1/chat/completions` 代理。
- **API / Custom compatible API**：继续支持 OpenAI 兼容的 chat-completions endpoint。不同 API 选项分别保存 key/model，切换时不会把旧 provider 的 key 发给新 provider。
- **Codex account**：使用官方 Codex CLI 的 ChatGPT 登录。可直接使用已有登录，也可点 Sign in。模型留空采用账户默认。
- **Grok account**：使用官方 Grok Build CLI 登录。模型留空采用默认。CLI 需安装于常见路径或手动指定 executable。

文本 preset（Daily/Coding/自定义）与连接方式分别选择。API 模式保留预设的独立 endpoint/model override，并在界面明确提示；账户模式使用选中的账户模型，仍使用选中 preset 的文本规则。Test Polish 使用独立 Refiner，不会取消正在处理的听写。

Cursor SDK 也可显式安装：

```sh
npm install --prefix "$HOME/Library/Application Support/VoiceInput/CursorSDK" --save-exact @cursor/sdk@1.0.31
```

## 行为修复

1. **Daily**：去掉“修改但原词不变”的矛盾规则及激进的 ASR 猜词示例，增加中英清理示例。只有完整匹配旧内建提示词的 Daily 才迁移，用户修改过的提示词保持原样。系统角色与 JSON 中的转录材料分开，强调只改写、不回答或执行其中的指令。不能保证所有第三方模型都遵从提示词；实际结果仍须试用。
2. **运行状态**：显示实际 preset/连接/模型及成功、跳过原因。每次运行锁定配置；取消或开始新运行后，旧 HTTP/CLI 回调与 429 延迟重试不会交付旧文本。失败继续保留最佳文本。
3. **快捷键**：替换零尺寸、无法可靠点击的录制控件；真实 NSButton 可聚焦录制。支持 Fn、左右修饰键和组合键，录制期间暂停全局听写/字幕快捷键，结束、失焦、取消及超时都会清理状态。
4. **媒体暂停**：播放器探测与暂停合并为有期限的操作，保留恢复凭据，已退出的播放器不会因恢复而被重启。显示 Automation 拒绝与脚本错误。增加 Chrome/Safari 顶层 HTML5 audio/video 的定向暂停；只恢复本次暂停且仍在原文档、原元素上的媒体。
5. **词库**：自动学习默认开启。用户确认的明确英文词项替换可自动加入；AI 润色及中文疑似词进入待确认列表，可 Learn/Ignore，显示来源和次数。只比较转录与**翻译前**的润色结果；失败、取消及未插入的预审不学习。删除/忽略的候选不会马上重新冒出。

## 媒体支持范围与设置

General 页显示媒体状态并提供权限检查与 Automation 设置入口。系统播放器需要 macOS Automation 授权；Chrome/Safari 另外需要各浏览器手动允许 **JavaScript from Apple Events**。权限检查只读，不会为了申请权限而播放媒体。

支持的播放器以 General 页与 MediaController 的 adapter 列表为准。浏览器支持顶层 HTML5 audio/video；跨源 iframe、Web Audio、内部页面、IINA 不在本轮支持范围。网页导航、换源、手动播放/seek 后不会误恢复。自动播放策略可能拒绝恢复请求。没有使用会误启动 Apple Music 的全局媒体键兜底。

## CLI / SDK 隔离

Codex 使用忽略用户配置的 ephemeral、read-only 运行，关闭 shell、插件、hooks、浏览器等工具。Grok 使用本次临时目录与隔离配置，由官方 CLI 读取原登录，禁用工具/自动更新/记忆/兼容配置发现。Cursor 使用官方 SDK 的 local runtime、空 tools、空 settingSources，以及临时 session store。密钥和转录不放进 shell 拼接或命令参数；输出及超时有上限。进程错误不回显第三方 stderr 中可能含有的转录或密钥。

## 验证

- 70 项 Swift Testing 回归测试通过（10 个 suite），覆盖快捷键真实 AppKit/SwiftUI 控件、HTTP 请求/取消/重试、CLI 进程生命周期、媒体 adapter、词库与原有存储/ASR 边界。
- 5 项 Cursor SDK JavaScript 测试通过；已安装并验证加载官方 @cursor/sdk 1.0.31。没有使用 Cursor 用户 key 发真实请求，需在设置填入后 Test Polish。
- 使用生产 AccountPolishClient 代码进行 Codex/Grok 真实账户测试。固定输入：`嗯，明天我们我们先测试 VoiceInput，然后再发布，可以吗？`。两者均返回：`明天我们先测试 VoiceInput，然后再发布，可以吗？`；本机本次耗时约 5.7 秒 / 7.1 秒，不代表稳定延迟保证。
- Release 使用已安装 macOS 26.5 SDK 成功编译并 ad-hoc 签名，打包包含 Cursor helper resource。默认 macOS 27 SDK 的工具链问题见第一轮报告；仍有 CLT 注入的两个不存在的 linker search path warning。
- 没有操作用户正在播放的真实媒体、没有做真实麦克风/目标应用插入验收。媒体权限与具体网站行为需实际试用，不能把离线 fixture 当作“所有地方”都已支持。

官方依据：

- https://prod.cursor.com/docs/sdk/typescript
- https://prod.cursor.com/docs/sdk/python
- https://developers.openai.com/codex/auth
- https://developers.openai.com/codex/noninteractive
- https://docs.x.ai/build/overview
- https://docs.x.ai/build/cli/reference
