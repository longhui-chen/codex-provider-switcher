<div align="center">

# Codex Provider Switcher

**[Codex CLI](https://github.com/openai/codex) 的 macOS 原生小工具：切换默认提供方、按任意提供方恢复历史会话、管理多个 ChatGPT 账号 —— 不用手改 TOML，也不会弄丢登录。**

[English](README.md) | [简体中文](README.zh-CN.md)

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)
![swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift)
![deps](https://img.shields.io/badge/dependencies-none-24B36B)
![runtime](https://img.shields.io/badge/runtime-no%20server%20%C2%B7%20no%20watcher%20%C2%B7%20no%20network-8E8E93)
![license](https://img.shields.io/badge/license-MIT-26A69A)

![Codex Provider Switcher 主窗口](docs/screenshot.png)

*截图基于填充了示例账号与会话的演示 `CODEX_HOME` 生成 —— 图上没有任何真实数据。*

</div>

---

## 这个仓库解决什么问题

Codex CLI 的配置在 `~/.codex/config.toml`，一切行为 —— 新会话、交互式历史选择器、`codex resume` —— 都跟随其中 `model_provider` 设的默认提供方。这个设计很干净，直到你遇到下面任意一种处境：

| 没有这个工具 | 有这个工具 |
|---|---|
| 在官方 OpenAI 后端和自定义代理之间切换意味着手改 TOML，改错了也没有备份兜底 | 一键切换，自带原子备份和快照还原 |
| 想用「非默认」的提供方恢复某个旧会话，就要每次记得 `-c 'model_provider="…"'` 覆盖参数的写法 | 选会话、选提供方，命令自动生成、保证正确 |
| 官方历史选择器永远以当前默认提供方打开 | 选择器永远显式走 OpenAI，与当前默认无关 |
| 多个 ChatGPT 账号只能 `codex logout && codex login` —— 而 **logout 会在服务端吊销当前账号的 refresh token**，存下来的登录悄悄失效 | 账号存在本地快照库里，靠换文件切换 —— 什么都不吊销 |
| 多账号全靠脑子记「现在激活的是哪个号」 | 激活账号随时可见，可按次切换 |

如果你只用一个提供方、一个账号，那不需要这个工具。如果不是 —— 往下看。

## 功能

- **实时状态**：`config.toml` 的当前提供方、模型、评审模型、响应存储策略，以及是否配置了自定义代理 —— 包括对**任意**非 `openai` 的 `[model_providers.*]` 表的**动态检测**，无论它叫什么名字。
- **安全切换默认提供方**：官方/代理一键互切，切换前先落一份原子备份到 `config.backups/`，切回时代理配置原样还原。
- **会话浏览器**：基于轻量的 `session_index.jsonl`，支持按标题或 ID 搜索。
- **按次选择提供方**：任选一条历史会话，走官方或走代理恢复，命令显式携带提供方覆盖参数，全局默认不受影响。
- **多账号管理**：把 `auth.json` 快照存进 `~/.codex/auth-store/<account>/`，换账号就是换文件；每次切换前先把离场账号刷新过的令牌回存进快照库。
- **一键终端流**：「切换并复制官方命令」一步完成切账号 + 把可直接粘贴的 `resume` 命令放进剪贴板。
- **支持 `CODEX_HOME`**：与 codex CLI 同名约定，指向隔离目录运行 —— 演示、测试两相宜。
- **该有快捷键的地方都有**：<kbd>⌘R</kbd> 刷新、<kbd>⌘F</kbd> 筛选历史、<kbd>⇧⌘O</kbd> 打开官方历史选择器。
- **天生安静**：没有 HTTP 服务、没有浏览器进程、没有 watcher、没有定时器、没有常驻代理、没有第三方依赖。

## 使用场景

**1. 代理 + 官方的日常。** 日常工作走自定义代理（`[model_providers.*]` 指向你自己的网关），但偶尔需要官方 OpenAI 后端 —— 代理暂时不支持的特性，或想对比输出。让代理做默认；需要官方时，要么切默认用一阵再切回来，要么只把某一条会话走官方恢复，默认不动。

**2. 多个 ChatGPT 账号。** 工作号 + 个人号，或按额度分用的几个号。每个号登录一次、存进快照库，之后在应用里按需切换。只有切换**之后**启动的进程看到新登录 —— 正在运行的会话保持原登录。

**3. 共享或轮换的代理。** 代理端点时不时变化。改一次 `config.toml`（应用不会和你抢这个文件 —— <kbd>⌘R</kbd> 随时重读），提供方表动态识别，没有硬编码 ID。

**4. 演示、截图、沙箱。** `CODEX_HOME=/tmp/demo` 指向一个临时目录，应用就基于示例数据渲染出完整界面 —— 上面的截图就是这么生成的，不暴露任何人的账号和会话标题。

## 快速开始

**环境要求：** macOS 14+，Xcode 工具链（Swift 5.10+）。注意：部分机器上独立安装的 Command Line Tools 自带的 swift 版本低于 SDK 要求，会构建失败 —— 遇到就换 Xcode 工具链。

```bash
git clone https://github.com/longhui-chen/codex-provider-switcher.git
cd codex-provider-switcher
./scripts/build-app.sh          # swift build -c release + 打包 .app
open "$HOME/Applications/Codex Provider Switcher.app"
```

应用打开即可用，直接读取 `~/.codex`。没有引导向导、没有登录页 —— 它只读 Codex CLI 已经写好的东西。

## 使用说明

### 看状态

左栏永远是 `config.toml` 的当前真实状态：模式（官方 / 代理 / 自定义）、提供方 ID、模型、响应存储、代理表是否存在。<kbd>⌘R</kbd> 全量重读。

### 切换默认提供方

**设为官方 / 设为代理** 改变的是**之后新启动**的 Codex 进程用什么。首次切换会往 `~/.codex/config.backups/` 落一份原子备份；代理表和一切无关配置逐字节保留，切回无损。

### 浏览并恢复历史

中栏列出 `session_index.jsonl` 里的全部会话（去重、新在前）。选中一条，右栏即可选择用哪种提供方在 Terminal 里打开，或复制完整命令。生成的命令永远显式携带 `-c 'model_provider="…"'` 覆盖参数 —— 你选的是什么，跑的就是什么，与全局默认无关。

### 管理多个官方账号

OpenAI 没有原生多账号切换，本应用采用快照互换方案：

1. 终端执行 `codex login`，在浏览器登录另一个账号。**切勿用 `codex logout` 换号** —— logout 会在服务端吊销当前账号的 refresh token，导致你正要离开的账号已保存的快照失效。裸 `codex login` 覆盖当前登录，不吊销任何东西。
2. 回到应用，点「保存当前登录到账号库」。
3. 每个账号重复一次。

用「切换并复制官方命令」切换并把官方 `resume` 命令放进剪贴板，或「只切换」仅换号。切换前建议关闭正在运行的 Codex 会话：活会话可能刷新令牌并在换文件后覆写 `auth.json`。

> 一键按钮很克制：账号已是当前登录时，它完全不动 `auth.json`，只复制命令。

## 工作原理

| 路径 | 访问方式 | 用途 |
|---|---|---|
| `~/.codex/config.toml` | 读 + 切换时写 | 默认提供方、模型、代理表 |
| `~/.codex/config.backups/` | 写 | 切换前的原子备份 |
| `~/.codex/session_index.jsonl` | 只读 | 会话标题、ID、时间戳 |
| `~/.codex/auth.json` | 读 + 互换 | 当前登录（邮箱取自 `id_token` JWT 的 `email` claim） |
| `~/.codex/auth-store/<account>/` | 读 + 写 | 每账号登录快照 |
| `~/.codex/auth-store/accounts.json` | 读 + 写 | 账号索引 |

- 除此之外什么都不读。API key 和代理凭据文件永不打开。
- 令牌**内容**永不进入界面 —— 唯一显示的是邮箱 claim。
- 所有写入都是原子操作；账号切换在文件锁下进行，安装目标快照前先把离场账号刷新过的令牌回存进快照库。
- `CODEX_HOME` 会把上述所有路径重定向到隔离根目录。

## 常见问题

**为什么生成的命令带 `--dangerously-bypass-approvals-and-sandbox`？**
这些命令面向已建立信任会话的无交互终端启动，与本工具围绕的用法配套。不合你的流程，就把命令复制出来删掉这个参数。

**这个应用会存储或传输我的令牌吗？**
存储：会，在本地 `~/.codex/auth-store/` —— 这就是它的机制。传输：永不。二进制里没有任何网络代码。

**我的代理提供方被支持吗？**
只要它在 `config.toml` 里声明为 `[model_providers.<id>]` 表、ID 不是 `openai`，就支持。ID 动态识别，包括定义在多行字符串之后的表。

**为什么做原生应用而不是脚本？**
单行切换是脚本的事；这个应用的价值在常驻可见的实时状态、会话浏览器和安全的快照管理 —— 这些你希望放在一个带快捷键、零运行时负担的窗口里。

**为什么界面是中文？**
它最初是个人工具。欢迎贡献英文本地化 —— 字符串面小而集中。

## 开发

```bash
swift test                 # 13 个单测覆盖 TOML/登录/会话逻辑
swift build -c release
./scripts/build-app.sh     # 构建 + 打包 .app 到 ~/Applications
```

核心逻辑（`CodexProviderCore`）全部由基于夹具 `CODEX_HOME` 目录的单测覆盖 —— 没有任何测试触碰你真实的 `~/.codex`。

## 免责声明

这是一个独立工具，不是 OpenAI 官方产品。它操作的是 Codex CLI 的本地文件；虽然每次写入都有备份或原子性保障，在把登录交给它之前，欢迎审阅代码（很小 —— 这正是设计目的）。
