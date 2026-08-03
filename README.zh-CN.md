<p align="center">
  <img src="docs/dash-icon.png" alt="Dash" width="120" height="120">
</p>

# Dash for Cloudflare

[English](README.md) | [简体中文](README.zh-CN.md)

Dash 是使用 SwiftUI 构建的原生 iPhone Cloudflare 客户端。它通过 OAuth 2.0 Authorization Code + PKCE 登录，聚焦手机上日常会管的那几类 Cloudflare 资源。

安装后的名称是 **Dash**，Bundle ID 为 `sh.xat.dash.app`，回调地址为 `dash://oauth/callback`，App Store 名称使用 **Dash for Cloudflare**。

## 功能

目录里的资源面，外加让它们能用起来的壳：

| 功能 | 能做什么 |
| --- | --- |
| **Domains** | 域名、DNS、缓存清理、域名设置、流量 / WAF / Web Analytics |
| **Registrations** | 账户下的注册域名、状态与到期信息 |
| **Email Routing** | 按域名管理路由、设置与 Destination Addresses |
| **Workers** | 查看脚本、部署历史与切流、自定义域、`workers.dev`、分析、Workers Builds |
| **Pages** | 查看项目、部署与日志、重试/回滚、自定义域、构建 Live Activity |
| **R2** | 桶浏览/上传/预览、公开 URL、Files 挂载、分享扩展与快捷指令 |
| **KV** | Namespace、key 列表、读取与创建·编辑·删除 |
| **Tunnels** | 实验功能；在 Settings → Experimental 中开启 |

壳层能力：Home 启动器、Resources 目录、Watchtower 流量图表与 Cloudflare 通知历史、Account / Domain Metrics 小组件、Settings（推送告警、集成、About）、多账户 OAuth，以及仅 iPhone 的单栈导航。

暂不覆盖：D1、Queues、Vectorize、Secrets Store、Images、Stream、Access，以及 iPad / 分栏布局。

## 目录

| 路径 | 用途 |
| --- | --- |
| `apps/ios` | iOS 17+ SwiftUI App、Xcode 工程、单元测试和 UI 测试 |
| `packages/cloudflare-api` | 无第三方依赖的 Swift OAuth 与 Cloudflare REST/GraphQL 客户端 |
| `packages/SwiftGlobeKit` | 原生 SwiftUI + Metal 点阵地球组件库 |
| `apps/web` | 落地页 + Hono 边缘应用（`dash-relay`），域名 `https://dash.xat.sh` |
| `packages/ui` | 从原 workspace 保留、未被 App 使用的 Web 组件库 |

## 环境要求

- Xcode 26 或更新，并配备 iOS Simulator
- Swift 6
- 当前 LTS 的 Node.js 与 pnpm 11（边缘 Worker 与 web 包）

## 配置 OAuth

```sh
cp apps/ios/Config/Secrets.xcconfig.example apps/ios/Config/Secrets.xcconfig
```

在本地配置中填写 Cloudflare OAuth Client ID 和 relay 的 HTTPS `/oauth/callback` 地址。Cloudflare 控制台只注册 HTTPS 地址；relay 会把最终回调转换成 `dash://oauth/callback`。

真实账户登录会在一次授权中请求 Dash 当前功能使用的全部读写权限；Demo 仍保持只读。之后再次走 OAuth 也会请求同一套完整权限。

调整 scope 时，Cloudflare OAuth 客户端必须启用完全相同的 scope ID，并重新确认更新后的授权请求。

## 开发与验证

```sh
open apps/ios/Dash.xcodeproj
pnpm ios:build
pnpm ios:test
pnpm api:test
pnpm globe:test
pnpm lint
pnpm lint:fix
pnpm typecheck
```

发布新版 App 前需要重新部署边缘应用（落地页 + OAuth relay）：

```sh
pnpm install
pnpm --filter @dash/web exec wrangler login
pnpm web:deploy   # versions upload → versions deploy
```

部署后确认 `https://dash.xat.sh/oauth/callback` 仍 302 到 `dash://oauth/callback`，并在 Cloudflare OAuth 客户端与 `DASH_REDIRECT_URI` 中使用该 HTTPS 地址。

## License

[MIT](LICENSE)
