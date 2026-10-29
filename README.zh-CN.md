# Bot27

[English](README.md)

**一个更好用、而且免费的 Grok Bot。** 
## 好在哪里

- **免费**：应用本身免费。模型用你已有的 Claude 或 ChatGPT 登录，或者你自己的 xAI key。
- **能操作浏览器和电脑**：bot 可以在 Chrome 里和你的 Mac 上帮你做事（使用 Claude 模型时）。
- **数据归你**：不用注册或登录 Bot27，聊天记录和记忆只存在你自己的 Mac 上。
- **自托管**：直接在你自己的电脑上运行，不需要服务器。

## 功能

- **多个 bot**：每个 bot 有自己的名字、头像、指令和模型。
- **三种模型来源**：Claude 通过 Claude Code CLI，GPT 通过 Codex CLI，Grok 通过 xAI API。
- **记忆**：每个 bot 有三个 Markdown 文件，聊天时会自动往里添加内容，你也可以手动编辑：
  - `SOUL.md`：bot 是谁
  - `USER.md`：你是谁
  - `MEMORY.md`：值得记住的事
- **每日笔记**：开始新会话时，上一个会话的结尾会存进每日笔记，bot 之后可以搜索。
- **会话**：发送 `/new` 或 `/reset` 开始新会话。聊天太长时会自动总结，而不是直接截断。
- **任务和定时任务**：可以手动运行的任务，也可以按时间自动运行的定时任务。定时任务在单独的会话里运行。
- **连接**（仅限 Claude）：Gmail、Google 日历等 claude.ai 连接器。只能读取，唯一的例外是可以写邮件草稿。
- **电脑操作和浏览器操作**（仅限 Claude）：默认关闭，可以为每个 bot 单独开启。

## 运行要求

- macOS 14 或更高版本
- Swift 5.9（来自 Xcode 或 Command Line Tools）
- 至少满足以下一项：
  - 安装 [Claude Code](https://claude.com/claude-code)，并在终端运行一次 `claude` 完成登录
  - 安装 Codex CLI，并用 `codex login` 登录
  - 一个 xAI API key

## 构建

```bash
./build.sh
```

```bash
open build/Bot27.app
```

如果钥匙串里有名为 "Bot27 Local Signing" 的证书，`build.sh` 会用它给应用签名。证书不变，macOS 就会在每次重新构建后保留"屏幕录制"和"辅助功能"权限。

## 数据

聊天记录和设置都只保存在你的 Mac 上，位于 `~/Library/Application Support/Bot27/`。每个 bot 的文件在 `memory/<bot-id>/` 里。xAI API key 保存在 macOS 钥匙串中。
