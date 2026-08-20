<div align="center">

# Codex Provider Switcher

[English](README.md) | [简体中文](README.zh-CN.md)

**A native macOS utility for the [Codex CLI](https://github.com/openai/codex): switch the default provider, resume any session through either provider, and juggle multiple ChatGPT accounts — without hand-editing TOML or losing logins.**

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)
![swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift)
![deps](https://img.shields.io/badge/dependencies-none-24B36B)
![runtime](https://img.shields.io/badge/runtime-no%20server%20%C2%B7%20no%20watcher%20%C2%B7%20no%20network-8E8E93)
![license](https://img.shields.io/badge/license-MIT-26A69A)

![Codex Provider Switcher main window](docs/screenshot.png)

*Screenshot captured against a demo `CODEX_HOME` filled with sample accounts and sessions — nothing on it is real data.*

</div>

---

## Why this exists

The Codex CLI is configured through `~/.codex/config.toml`, and everything — new sessions, the interactive history picker, `codex resume` — follows the `model_provider` default set there. That design is clean until you live in any of these situations:

| Without this app | With this app |
|---|---|
| Switching between the official OpenAI backend and a custom proxy means hand-editing TOML, with no backup when you fat-finger it | One click, with an atomic backup and snapshot restore |
| Resuming an old session through a *different* provider than your default means remembering the `-c 'model_provider="…"'` override syntax every time | Pick the session, pick the provider, done — the override is generated correctly |
| The official history picker always opens with your default provider | The picker is always opened explicitly through OpenAI, regardless of the current default |
| Multiple ChatGPT accounts require `codex logout && codex login` — and **logout revokes the current account's refresh token server-side**, so saved logins silently die | Accounts live in a local snapshot store and swap by file — nothing is ever revoked |
| Multi-account setups need mental tracking of "which login is active right now" | The active account is shown and switchable per-session-launch |

If you only ever use one provider and one account, you don't need this tool. If you don't — read on.

## Features

- **Live status** of `config.toml`: active provider, model, review model, response-storage policy, and whether a custom proxy is configured — including **dynamic detection** of *any* non-`openai` `[model_providers.*]` table, whatever it is named.
- **Safe default switching** between official and proxy, with an atomic `config.backups/` snapshot taken first, and your proxy settings restored intact when you switch back.
- **Session browser** over the lightweight `session_index.jsonl`, with search by title or ID.
- **Per-launch provider choice**: open any selected session through the official backend or your proxy with an explicit provider override, without touching the global default.
- **Multi-account management**: save `auth.json` snapshots into `~/.codex/auth-store/<account>/`, switch the active login by swapping files, and sync refreshed tokens back into the store before every switch.
- **One-click terminal flow**: "switch account + copy official command" puts a paste-ready `resume` command on your clipboard in a single step.
- **Honors `CODEX_HOME`** to run against an isolated directory — same convention as the codex CLI, handy for demos and testing.
- **Keyboard first where it matters**: <kbd>⌘R</kbd> refresh, <kbd>⌘F</kbd> filter history, <kbd>⇧⌘O</kbd> open the official history picker.
- **Quiet by design**: no HTTP server, no browser process, no watcher, no timer, no menu-bar agent, no third-party dependency.

## Use cases

**1. Proxy + official, day to day.** You route daily work through a custom proxy (`[model_providers.*]` with your own gateway) but occasionally need the official OpenAI backend — for a feature the proxy doesn't support yet, or to compare outputs. Keep the proxy as the default; when you need official, either switch the default for a while and switch back, or resume one specific session through OpenAI and leave the default alone.

**2. Multiple ChatGPT accounts.** A work account and a personal account, or several accounts with separate quotas. Log in once per account, capture each into the store, and switch from the app whenever you start a new context. Only processes launched *after* the switch see the new login — running sessions keep theirs.

**3. Shared or rotating proxies.** Your proxy endpoint or gateway changes from time to time. Edit `config.toml` once (the app never fights you for the file — it re-reads on <kbd>⌘R</kbd>), and the app picks up the provider table dynamically, no hardcoded IDs.

**4. Demos, screenshots, and sandboxes.** Point the app at a throwaway directory with `CODEX_HOME=/tmp/demo` and it renders a fully functional UI against sample data — that's exactly how the screenshot above was produced, without exposing anyone's account or session titles.

## Getting started

**Requirements:** macOS 14+, Xcode toolchain (Swift 5.10+). Note that on some setups the standalone Command Line Tools swift is older than the SDK and will fail to build — use the Xcode toolchain if that happens.

```bash
git clone https://github.com/longhui-chen/codex-provider-switcher.git
cd codex-provider-switcher
./scripts/build-app.sh          # swift build -c release + bundle .app
open "$HOME/Applications/Codex Provider Switcher.app"
```

The app works immediately against `~/.codex`. No setup wizard, no sign-in — it only ever reads what the Codex CLI already wrote.

## Usage

### Reading the status

The left column always shows the current truth of `config.toml`: mode (official / proxy / custom), provider ID, models, response storage, and whether a proxy table exists. <kbd>⌘R</kbd> re-reads everything.

### Switching the default provider

**设为官方 / 设为代理** changes what *newly started* Codex processes use. The first switch takes an atomic backup into `~/.codex/config.backups/`; your proxy tables and any unrelated settings are preserved byte-for-byte, so switching back is lossless.

### Browsing and resuming history

The middle column lists every session from `session_index.jsonl` (deduplicated, newest first). Select one, and the right column offers to open it in Terminal through either provider, or copy the exact command. The generated command always carries an explicit `-c 'model_provider="…"'` override, so what you picked is what runs — independent of the global default.

### Managing multiple official accounts

OpenAI has no native multi-account switching, so this app uses a snapshot-swap approach:

1. In a terminal, run `codex login` and sign in with the other account in the browser. **Never run `codex logout` to change accounts** — logout revokes the current account's refresh token server-side, which invalidates the snapshot stored for the account you are leaving. Plain `codex login` overwrites the active login without revoking anything.
2. Back in the app, click 保存当前登录到账号库.
3. Repeat for each account.

Switch with 切换并复制官方命令 (switch + put the official `resume` command on the clipboard) or 只切换 (switch only). Close running Codex sessions before switching: a live session can refresh its tokens and overwrite `auth.json` after the swap.

> The one-click button is intentionally eager: when the account is already active it doesn't touch `auth.json` at all, it just copies the command.

## How it works

| Path | Access | Purpose |
|---|---|---|
| `~/.codex/config.toml` | read + write on switch | default provider, models, proxy tables |
| `~/.codex/config.backups/` | write | atomic pre-switch backup |
| `~/.codex/session_index.jsonl` | read only | session titles, IDs, timestamps |
| `~/.codex/auth.json` | read + swap | active login (email derived from the `id_token` JWT `email` claim) |
| `~/.codex/auth-store/<account>/` | read + write | per-account login snapshots |
| `~/.codex/auth-store/accounts.json` | read + write | account index |

- Nothing else is read. API keys and provider credential files are never opened.
- Token *contents* never reach the UI — the only thing ever displayed is the email claim.
- All file writes are atomic; account switching runs under a file lock and syncs the leaving account's refreshed tokens back into the store before installing the target snapshot.
- `CODEX_HOME` redirects every path above to an isolated root.

## FAQ

**Why do the generated commands carry `--dangerously-bypass-approvals-and-sandbox`?**
Because these commands are meant for headless terminal launches of an existing, trusted session, matching the flag set the tool was built around. If that's not your workflow, copy the command and drop the flag.

**Does this app store or transmit my tokens?**
Store: yes, locally, in `~/.codex/auth-store/` — that's the mechanism. Transmit: never. There is no network code in the binary at all.

**Is my proxy provider supported?**
If it's declared as a `[model_providers.<id>]` table in `config.toml` with any ID other than `openai`, yes. The ID is discovered dynamically, including tables defined after multiline strings.

**Why a native app and not a script?**
One-line switches are scripts; this app's value is the live status surface, the session browser, and safe snapshot management — things you want in a window you keep around, with keyboard shortcuts and zero runtime baggage.

**Why is the UI in Chinese?**
It started as a personal tool. The docs are bilingual ([简体中文](README.zh-CN.md)); English UI localization is a welcome contribution — the string surface is small and centralized.

## Development

```bash
swift test                 # 13 unit tests over the TOML/auth/session logic
swift build -c release
./scripts/build-app.sh     # build + bundle the .app into ~/Applications
```

The core logic (`CodexProviderCore`) is fully covered by tests using fixture `CODEX_HOME` directories — no test touches your real `~/.codex`.

## Disclaimer

This is an independent utility, not an official OpenAI product. It manipulates local files that belong to the Codex CLI; while every write is backed up or atomic, review the code (it's small — that's the point) before trusting it with your logins.
