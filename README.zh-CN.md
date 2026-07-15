# Dash for Cloudflare

[English](README.md) | [简体中文](README.zh-CN.md)

Dash 是使用 SwiftUI 构建的原生 iPhone Cloudflare 客户端。它通过 OAuth 2.0 Authorization Code + PKCE 登录，可管理 Zones、DNS、缓存、安全设置、Workers、Pages、R2、KV、D1、Queues、Vectorize、Secrets Store、账户服务和分析数据。

安装后的名称是 **Dash**，Bundle ID 为 `sh.xat.dash`，回调地址为 `dash://oauth/callback`，App Store 名称使用 **Dash for Cloudflare**。

## 目录

| 路径 | 用途 |
| --- | --- |
| `apps/ios` | iOS 17+ SwiftUI App、Xcode 工程、单元测试和 UI 测试 |
| `packages/cloudflare-api` | 无第三方依赖的 Swift OAuth 与 Cloudflare REST/GraphQL 客户端 |
| `apps/relay-worker` | 将注册的 HTTPS OAuth 回调转到 `dash://` 的无状态 Worker |
| `packages/ui` | 从原 workspace 保留、未被 App 使用的 Web 组件库 |

## 配置 OAuth

```sh
cp apps/ios/Config/Secrets.xcconfig.example apps/ios/Config/Secrets.xcconfig
```

在本地配置中填写 Cloudflare OAuth Client ID 和 relay 的 HTTPS `/oauth/callback` 地址。Cloudflare 控制台只注册 HTTPS 地址；relay 会把最终回调转换成 `dash://oauth/callback`。

## 开发与验证

```sh
open apps/ios/Dash.xcodeproj
pnpm ios:build
pnpm ios:test
pnpm api:test
pnpm lint
pnpm lint:fix
pnpm typecheck
```

发布新版 App 前需要重新部署 relay：

```sh
pnpm install
pnpm --filter @dash/relay-worker exec wrangler login
pnpm --filter @dash/relay-worker run deploy
```

部署后，把 Cloudflare OAuth 客户端和 `DASH_REDIRECT_URI` 更新为 `https://dash-relay.<subdomain>.workers.dev/oauth/callback`。

## License

[MIT](LICENSE)
