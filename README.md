# 快译浮窗（QuickEnglish）

一个 macOS 菜单栏工具，把中文快速改写成适合帖子、评论和回复的自然英文。它是为减少“先写中文、再反复改英文”的切换成本而做的。

## 使用

运行 `build/快译浮窗.app`，首次打开后选择 OpenAI、DeepSeek、Ollama 或其他 OpenAI 兼容接口，填写你自己的 API 地址、模型和 Key。按 `Control + Option + E` 呼出浮窗，按 `Command + Enter` 生成并复制结果。重新构建运行 `./build.sh`。

## 注意

API Key 只应保存在本机设置中，绝不要提交到 Git。不同模型的费用、隐私政策和输出质量由用户自行承担；生成内容发布前请人工核对。问题和建议请通过 GitHub Issues 联系作者。

配套 AI 工作流见 [`skills/quickenglish-reply`](skills/quickenglish-reply/SKILL.md)。

一个原生 macOS 菜单栏小工具，用于把中文快速改写成适合帖子、回复和评论的自然英文。应用使用系统 AppKit/WebKit 构建，不需要安装任何依赖。

## 使用

1. 运行 `build/快译浮窗.app`。
2. 首次打开时选择 OpenAI、DeepSeek、Ollama 或自定义的 OpenAI 兼容接口。
3. 在任意界面按 `Control + Option + E` 呼出或收起浮窗；可在设置中更换快捷键。
4. 输入中文，按 `Command + Enter` 生成英文。
5. 默认自动复制结果，回到原应用粘贴即可。
6. 如需关机或重启后自动出现，在设置中开启“开机自动启动”；也可从顶部菜单栏的“译”菜单快速切换。

API Key 只保存在这台 Mac 的用户专属配置目录中，密钥文件权限为 `600`。这避免本地临时签名版本更新时反复弹出钥匙串授权窗口。

如果 API Key 曾由旧版保存在 macOS 钥匙串，可在设置中点击“从旧钥匙串恢复 API Key”。恢复只在用户主动点击时访问一次旧钥匙串，密钥不会显示在界面或日志中。

DeepSeek 预设使用 `https://api.deepseek.com/chat/completions` 和快速模型 `deepseek-v4-flash`。`https://platform.deepseek.com/api_keys` 是 API Key 管理网页，不是接口地址。

## 重新构建

```bash
./build.sh
```
