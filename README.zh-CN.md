# monorepo-template

[English](README.md) | [简体中文](README.zh-CN.md)

一个用于应用和共享包的 TypeScript monorepo 模板。项目使用 pnpm workspace、Turborepo、统一的工具链 catalog，并自带可直接使用的 React 组件库。

由 [@withxat](https://github.com/withxat) 维护。

## 包含内容

- pnpm 11 workspace，通过 catalog 管理共享依赖版本
- 使用 Turborepo 运行开发、构建、类型检查和 lint 任务
- 通过 [`@withxat/tsconfig`](https://npmx.dev/@withxat/tsconfig) 使用 TypeScript 6
- 通过 [`@withxat/eslint-config`](https://npmx.dev/@withxat/eslint-config) 使用 ESLint 10 完成 lint 和格式化
- 使用 Lefthook 在提交前执行检查
- 一个基于 React 19 和 Tailwind CSS v4 的共享组件包
- 当前完整的 shadcn/ui `base-nova` 组件集，底层使用 Base UI 原语组件
- 使用 [`cnfast`](https://github.com/aidenybai/cnfast) 实现 `cn`
- 使用 [`foxact`](https://github.com/sukkaw/foxact) Hook，包括响应式判断 `useIsMobile`
- 只公开 `SearchIcon` 这类带 `Icon` 后缀的 Lucide 图标类型
- 通过 `trustPolicy: no-downgrade` 检查 pnpm 依赖的供应链风险

## 项目结构

```text
monorepo-template/
├── apps/                         # 应用 workspace
├── packages/
│   └── ui/                       # 共享 React 组件库
│       ├── src/
│       │   ├── components/       # shadcn/ui 组件
│       │   ├── hooks/            # 共享 React hooks
│       │   ├── lib/              # 共享工具函数
│       │   ├── styles/           # Tailwind 和主题样式
│       │   └── types/            # 公开子路径的类型声明
│       ├── components.json       # shadcn/ui base-nova 配置
│       └── package.json
├── eslint.config.ts              # 根目录 ESLint flat config
├── lefthook.yml                  # 提交前检查
├── package.json                  # 根目录脚本和工具链依赖
├── pnpm-workspace.yaml           # workspace、catalog 和 pnpm 策略
├── tsconfig.json                 # 根目录 TypeScript 配置
└── turbo.json                    # Turborepo 任务定义
```

workspace 已包含 `apps/*` 和 `packages/*`。添加第一个应用时再创建 `apps` 目录即可。

## 开始使用

### 环境要求

- 当前仍受支持的 [Node.js](https://nodejs.org) 版本
- Node.js 发行版附带的 [Corepack](https://nodejs.org/api/corepack.html)
- Git

### 安装

```sh
corepack enable
pnpm install
```

根目录的 `packageManager` 字段固定使用 pnpm 11.9.0，Corepack 会让所有开发者使用同一个 pnpm 版本。

### 命令

| 命令 | 说明 |
| --- | --- |
| `pnpm dev` | 运行 workspace 中的开发任务 |
| `pnpm build` | 构建定义了 `build` 任务的包 |
| `pnpm typecheck` | 检查所有包的 TypeScript 类型 |
| `pnpm lint` | 使用 ESLint 检查所有包 |
| `pnpm lint:fix` | 修复 lint 和格式问题 |

Turborepo 会在整个 workspace 中运行这些命令，并缓存已经完成的任务。

## 添加应用

在 `apps/` 下创建目录，并添加自己的 `package.json`、TypeScript 配置和 ESLint 配置。共享 UI 包使用 workspace 协议，共享版本使用 catalog：

```json
{
	"name": "web",
	"private": true,
	"dependencies": {
		"react": "catalog:react",
		"react-dom": "catalog:react",
		"ui": "workspace:*"
	},
	"devDependencies": {
		"@types/react": "catalog:react",
		"@types/react-dom": "catalog:react",
		"typescript": "catalog:devtool"
	}
}
```

应用应继承共享的 TypeScript 和 ESLint 配置：

```jsonc
// apps/web/tsconfig.json
{
	"extends": "@withxat/tsconfig",
	"compilerOptions": {
		"jsx": "react-jsx"
	},
	"include": ["src"]
}
```

```ts
// apps/web/eslint.config.ts
import { xat } from '@withxat/eslint-config'

export default xat()
```

根据需要添加 `dev`、`build`、`typecheck` 和 `lint` 脚本。只要名称和 `turbo.json` 中的任务一致，Turborepo 就会自动执行。

## 共享 UI 包

`packages/ui` 保存共享组件源码。应用通过子路径导入每个组件：

```tsx
import { Button } from 'ui/button'
import { Card, CardContent, CardHeader } from 'ui/card'
import { SearchIcon } from 'ui/icons'
import { cn } from 'ui/utils'

export function SearchCard() {
	return (
		<Card className={cn('max-w-md')}>
			<CardHeader>搜索</CardHeader>
			<CardContent>
				<Button>
					<SearchIcon />
					打开搜索
				</Button>
			</CardContent>
		</Card>
	)
}
```

在应用入口处导入一次共享样式：

```ts
import 'ui/styles'
```

### Tooltip provider

使用 tooltip 的应用应在接近根节点的位置挂载 `TooltipProvider`：

```tsx
import type { ReactNode } from 'react'

import { TooltipProvider } from 'ui/tooltip'

export function Providers({ children }: { children: ReactNode }) {
	return <TooltipProvider>{children}</TooltipProvider>
}
```

### 工具函数和 hooks

`ui/utils` 从 cnfast 导出 `cn`。调用方式和常见的 `clsx` 加 `tailwind-merge` 辅助函数相同：

```ts
import { cn } from 'ui/utils'

const className = cn('px-2 py-1', active && 'bg-primary')
```

`ui/hooks` 目前导出 `useIsMobile`。它使用 foxact 的 `useMediaQuery`，SSR 默认值为 `false`：

```tsx
import { useIsMobile } from 'ui/hooks'

const isMobile = useIsMobile()
```

### 图标后缀限制

Lucide 图标统一从 `ui/icons` 导入。公开类型只包含带 `Icon` 后缀的名称：

```tsx
import { SearchIcon } from 'ui/icons' // 正确
import { Search } from 'ui/icons' // TypeScript 报错
```

这个限制只作用于 `ui/icons`。应用直接从 `lucide-react` 导入时可以绕过限制。如果希望整个 monorepo 统一命名，请只通过共享包导入 Lucide 图标。

### 公开导出

| 导入路径 | 内容 |
| --- | --- |
| `ui/<component>` | `src/components` 中的单个组件 |
| `ui/utils` | cnfast 的 `cn` 辅助函数 |
| `ui/hooks` | 共享 React Hook |
| `ui/styles` | Tailwind 和主题样式 |
| `ui/icons` | 只公开带 `Icon` 后缀类型的 Lucide 图标 |
| `ui/sonner` | Sonner 的 `toast` API |

React、React DOM 和 Tailwind CSS 是对等依赖，版本由 workspace catalog 管理。

### 更新 shadcn/ui

在仓库根目录运行 shadcn CLI。`components.json` 会让生成路径和 import 与 workspace 的公开导出保持一致。

```sh
npx shadcn@latest add button -c packages/ui --overwrite
npx shadcn@latest add --all -c packages/ui --overwrite
```

生成后需要运行 lint、类型检查和应用测试。shadcn 的 import 路径或 SSR 行为与这个包的公开 API 不同时，生成代码可能需要少量调整。

## 依赖管理

共享版本保存在 `pnpm-workspace.yaml`：

| Catalog | 包含内容 |
| --- | --- |
| `devtool` | ESLint、TypeScript、Turborepo、Lefthook、Jiti 和共享配置 |
| `react` | React、React DOM 和对应的类型包 |
| `tailwind` | Tailwind CSS |

使用 catalog 引用，避免在多个包中重复版本号：

```json
{
	"devDependencies": {
		"typescript": "catalog:devtool"
	}
}
```

`trustPolicy: no-downgrade` 会拒绝可信证据弱于早期版本的新包。向 `minimumReleaseAgeExclude` 添加临时例外前，应先检查包内容和来源证明。

## Git hooks

Lefthook 会并行运行两个 pre-commit 任务：

1. `pnpm lint:fix` 检查格式，并将安全修复重新加入暂存区。
2. 暂存的 JavaScript 或 TypeScript 文件发生变化时，运行 `pnpm typecheck`。

提交信息使用 [Conventional Commits](https://www.conventionalcommits.org) 格式。

## License

[MIT](LICENSE)

## 作者

**monorepo-template** © [Xat](https://github.com/withxat)。由 Xat 创建并维护，感谢所有[贡献者](https://github.com/withxat/monorepo-template/graphs/contributors)。

[博客](https://blog.xat.sh) · GitHub [@withxat](https://github.com/withxat) · Telegram [@withxat](https://t.me/withxat) · X [@withxat](https://x.com/withxat) · [i@xat.sh](mailto:i@xat.sh)
