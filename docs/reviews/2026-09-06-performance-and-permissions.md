# Cursor 延迟、模型选择与更新权限修复

## 结果与使用

Cursor 选中且配置有效时，VoiceInput 启动后自动启动本次 App 专用的 Node worker，预热 SDK/运行环境和模型目录；关闭 App、禁用输入或切离 Cursor 时关闭 worker。没有注册后台常驻服务或登录项。每段听写使用新 agent 和内存记录，结束后删除，复用的是运行环境与连接，不累积聊天历史。

Providers 的模型字段现在以“搜索选择”为主要入口。Cursor、Codex、Grok、OpenRouter/兼容 API、Ollama、Soniox、Gemini 均读取对应目录；豆包当前通过所购 Resource ID 选择固定语音产品，因此保留资源项而不伪造模型列表。列表支持名称、ID、变体搜索、刷新与五分钟内存缓存；私有部署不提供目录时仍可通过铅笔手填。

Cursor Fast 是模型参数，例如 `composer-2.5` + `fast=true`。实际账户目录中的两个同名变体现显示为 **Composer 2.5 · Fast / Standard**。不能仅凭旧版没有显式传 `params` 就断言以前一定没启用 Fast，默认值也可能由服务端选择。

## 为什么常驻有帮助

原版每段听写都会启动 Node、加载 SDK、本地执行栈和账户环境、创建 agent，再调用云端模型，完成后退出。新版使用 SDK 公开的 `createAgentPlatform`、`prewarmLocalWorkspace` 和模型解析接口，持有 executor lease，并复用平台的模型目录缓存。

这里的 local runtime 只表示 Agent 循环运行在本机，模型仍在 Cursor 云端。常驻可以省掉重复准备，无法消除网络、服务端排队或模型首字等待。纯本地、无账户的预热约 0.25 秒；本机携带账户的完整预热约 3～4 秒，说明不能把全部延迟归因于 Node 启动本身。此准备被移到启动和设置变更后，通常与用户开始说话重叠；极早开始的首段仍可能等待预热。

固定测试句：`嗯，明天我们我们先测试 VoiceInput，然后再发布，可以吗？`

| 路径 | 本次各请求耗时 |
| --- | --- |
| 旧版，每次独立进程 | 8.05、8.27 秒 |
| 新版，同一预热 worker，普通参数 | 4.47、2.73、2.68 秒 |
| 新版，同一 worker，显式 Fast | 2.59、3.67、3.10 秒 |

八次生成均返回正确的去重复结果。此小样本未随机交错，不能当成稳定服务承诺，也不能据此比较模型绝对快慢。常驻版六次的中位数约 2.91 秒，旧版两次平均约 8.16 秒；主要可确认的改善是复用准备工作。首次常驻请求另有约 0.80 秒模型目录初始化，最终版已移到启动预取；最终启动预热验证为约 3.98 秒，`sendMs=0`，没有调用模型。

实测首字等待约 2～3 秒，仍是短文本请求的主要等待来源。Providers 显示运行环境是否准备好，以及最近一次总耗时、准备耗时、首字耗时，便于继续判断模型/网络变化。为了保留“失败也不丢文本”和完整输出校验，没有把未完成的流式片段提前粘贴到目标应用。

## 为什么更新后权限失效

旧 Makefile 使用 `codesign --sign -`。实际已安装包的 designated requirement 只有随二进制内容变化的 `cdhash`；相同 App 名称和 bundle ID 并不足以让每次构建具有相同的安全身份。macOS 的无障碍、麦克风、Automation 等隐私授权依赖签名身份要求。

本机已有可用 Apple Development 身份，现将其固定到 gitignored 的 `.signing.local.mk`。默认 release 构建必须使用证书，无法签名就明确失败，不会自动降级为 ad-hoc。临时 ad-hoc 开发包只由 `make dev-build` 显式生成，安装器拒绝它。

安装器验证新旧签名、bundle ID 和双向 designated requirement 兼容性，保留旧包备份。身份不兼容或包被改坏时拒绝替换。正常更新不强制关闭正在录音的 App；使用 `ALLOW_RUNNING_UPDATE=1` 时保留现有进程，下次正常退出重开加载新版。

**这次从 ad-hoc 迁移为证书签名，可能仍需要最后一次重新授权。** 旧 grant 不能靠代码安全地自动迁移。此后保持相同证书身份要求的更新，不再因临时签名变化而丢失匹配。未编辑或重置 TCC 数据库，未绕过系统权限。

签名配置与恢复步骤见 [SIGNING.md](../SIGNING.md)。

## 验证

82 项 Swift Testing 回归测试与 18 项 JavaScript 测试通过，另有真实证书签名/安装测试；日志随发布包保存。已验证持久进程复用、请求隔离、单次取消、超时/崩溃恢复、退出清理、Fast 参数传递和实际 Cursor/Codex/Grok 目录。真实 Cursor 目录有 267 个模型/参数组合，并确认 Composer Fast 与 Standard 的准确映射。模型目录查询和预热不发送生成请求。

签名测试使用同一证书签署两个内容不同的二进制：CDHash 不同但彼此满足身份要求；不兼容身份、ad-hoc release、篡改包均被拒绝，备份/回滚与运行中无中断更新均已测试。没有宣称实际操作系统的所有权限已经免交互授予；首轮证书版授权仍需用户正常完成。

官方依据：

- [Cursor SDK：local runtime、预热、模型参数与目录](https://prod.cursor.com/docs/sdk/typescript)
- [Apple TN3127：签名要求与隐私资源身份匹配](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Codex App Server：model/list](https://developers.openai.com/codex/app-server)
- [Grok CLI Reference](https://docs.x.ai/build/cli/reference)
- [Soniox Get models](https://soniox.com/docs/api-reference/stt/get_models)
- [Gemini Models API](https://ai.google.dev/api/models)
- [Ollama List models](https://docs.ollama.com/api/tags)

## Follow-up: ambiguous model variants

The real Cursor Grok 4.6 catalog has eight selections: four effort values × two speed values. All shared the same provider display name. The picker now includes every non-speed parameter in the title and shows the effective parameters beneath each row; titles may wrap. Verified all eight names against the live metadata endpoint, six catalog regression tests passed, and the certificate-signed release build passed. No generation requests were made for this verification.

## Follow-up: intermittent Cursor failures and Grok default

User requested Grok 4.6 with effort=low and fast=true as the default. Saved the current selection and Cursor profile model without changing the API key; new Cursor profiles also use this default.

Found a reproducible adapter bug: an 800 ms cleanup timeout in finally could replace completed polished text with worker_unhealthy, which was displayed as an API-key/model/quota error. Cleanup health now travels separately; completed text is delivered, and Swift retires the child before the next request. Agent deletion is also bounded. Original errors are retained. SDK stable codes distinguish authentication, permission, rate/usage limits, configuration and transient service/network errors without exposing raw SDK messages. Transient errors receive at most one retry with a fresh executor and unchanged model/parameters, inside the existing overall deadline. Cancellation and nontransient errors are not retried.

Validation: 83 Swift tests and 23 JavaScript tests passed, including successful-output preservation after hung cleanup, child retirement/restart, bounded retry, and non-retryable error classification. Certificate-signed release build passed. Three live synthetic Grok Low Fast requests succeeded (two before and one after the patch, approximately 4.7–5.6 seconds). The specific intermittent screenshot failure was not reproduced and cannot be conclusively attributed to cleanup; the new messages distinguish future failures. No private screenshot transcript was sent for testing.
