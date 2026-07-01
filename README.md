# monorepo-template

[English](README.md) | [简体中文](README.zh-CN.md)

A TypeScript monorepo template for applications and shared packages. It uses pnpm workspaces, Turborepo, a shared toolchain catalog, and a ready-to-use React component library.

Maintained by [@withxat](https://github.com/withxat).

## What is included

- pnpm 11 workspaces and catalogs for shared dependency versions
- Turborepo tasks for development, builds, type checking, and linting
- TypeScript 6 through [`@withxat/tsconfig`](https://npmx.dev/@withxat/tsconfig)
- ESLint 10 for linting and formatting through [`@withxat/eslint-config`](https://npmx.dev/@withxat/eslint-config)
- Lefthook checks before every commit
- A shared React 19 and Tailwind CSS v4 component package
- The current shadcn/ui `base-nova` component set, built with Base UI primitives
- [`cnfast`](https://github.com/aidenybai/cnfast) as the `cn` implementation
- [`foxact`](https://github.com/sukkaw/foxact) hooks, including the responsive `useIsMobile` helper
- A suffixed Lucide icon API that exposes names such as `SearchIcon`
- pnpm supply-chain checks through `trustPolicy: no-downgrade`

## Project structure

```text
monorepo-template/
├── apps/                         # Application workspaces
├── packages/
│   └── ui/                       # Shared React component library
│       ├── src/
│       │   ├── components/       # shadcn/ui components
│       │   ├── hooks/            # Shared React hooks
│       │   ├── lib/              # Shared utilities
│       │   ├── styles/           # Tailwind and theme styles
│       │   └── types/            # Public subpath declarations
│       ├── components.json       # shadcn/ui base-nova configuration
│       └── package.json
├── eslint.config.ts              # Root ESLint flat config
├── lefthook.yml                  # Pre-commit checks
├── package.json                  # Root scripts and toolchain dependencies
├── pnpm-workspace.yaml           # Workspace, catalogs, and pnpm policy
├── tsconfig.json                 # Root TypeScript config
└── turbo.json                    # Turborepo task definitions
```

The workspace patterns already include `apps/*` and `packages/*`. Create the `apps` directory when you add the first application.

## Getting started

### Requirements

- A current [Node.js](https://nodejs.org) release
- [Corepack](https://nodejs.org/api/corepack.html), included with supported Node.js distributions
- Git

### Install

```sh
corepack enable
pnpm install
```

The root `packageManager` field pins pnpm 11.9.0, so Corepack uses the same pnpm release for every contributor.

### Commands

| Command | Description |
| --- | --- |
| `pnpm dev` | Run workspace development tasks |
| `pnpm build` | Build packages that define a `build` task |
| `pnpm typecheck` | Type-check all packages |
| `pnpm lint` | Check all packages with ESLint |
| `pnpm lint:fix` | Fix lint and formatting issues |

Turborepo runs these commands across the workspace and caches completed tasks.

## Adding an application

Create a directory under `apps/` with its own `package.json`, TypeScript config, and ESLint config. Reference the shared UI package with the workspace protocol and use catalogs for shared versions:

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

Extend the shared TypeScript and ESLint packages in the application:

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

Add `dev`, `build`, `typecheck`, and `lint` scripts as needed. Turborepo picks up scripts whose names match tasks in `turbo.json`.

## Shared UI package

`packages/ui` contains the shared component source. Applications consume each component through a subpath export:

```tsx
import { Button } from 'ui/button'
import { Card, CardContent, CardHeader } from 'ui/card'
import { SearchIcon } from 'ui/icons'
import { cn } from 'ui/utils'

export function SearchCard() {
	return (
		<Card className={cn('max-w-md')}>
			<CardHeader>Search</CardHeader>
			<CardContent>
				<Button>
					<SearchIcon />
					Open search
				</Button>
			</CardContent>
		</Card>
	)
}
```

Import the shared stylesheet once from the application entry point:

```ts
import 'ui/styles'
```

### Tooltip provider

Applications that use tooltips should mount `TooltipProvider` near the root:

```tsx
import type { ReactNode } from 'react'

import { TooltipProvider } from 'ui/tooltip'

export function Providers({ children }: { children: ReactNode }) {
	return <TooltipProvider>{children}</TooltipProvider>
}
```

### Utilities and hooks

`ui/utils` exports `cn` from cnfast. It has the same call shape as the usual `clsx` and `tailwind-merge` helper:

```ts
import { cn } from 'ui/utils'

const className = cn('px-2 py-1', active && 'bg-primary')
```

`ui/hooks` currently exports `useIsMobile`, which uses foxact's `useMediaQuery` with an SSR fallback of `false`:

```tsx
import { useIsMobile } from 'ui/hooks'

const isMobile = useIsMobile()
```

### Suffixed icon names

Import Lucide icons from `ui/icons`. Its public type declaration only exposes suffixed names:

```tsx
import { SearchIcon } from 'ui/icons' // valid
import { Search } from 'ui/icons' // TypeScript error
```

This restriction applies to `ui/icons`. An application that imports `lucide-react` directly bypasses it, so keep Lucide imports behind the shared package if you want one naming convention across the monorepo.

### Public exports

| Import | Provides |
| --- | --- |
| `ui/<component>` | A component from `src/components` |
| `ui/utils` | The cnfast `cn` helper |
| `ui/hooks` | Shared React hooks |
| `ui/styles` | Tailwind and theme styles |
| `ui/icons` | Lucide icons with suffixed public types |
| `ui/sonner` | Sonner's `toast` API |

React, React DOM, and Tailwind CSS are peer dependencies. Their versions come from the workspace catalogs.

### Updating shadcn/ui

Run the shadcn CLI from the repository root. The package's `components.json` keeps generated files and imports aligned with the workspace exports.

```sh
npx shadcn@latest add button -c packages/ui --overwrite
npx shadcn@latest add --all -c packages/ui --overwrite
```

After generation, run lint, type checking, and any application tests. Generated code may need small adjustments when its import paths or SSR behavior differ from this package's public API.

## Dependency management

Shared versions live in `pnpm-workspace.yaml`:

| Catalog | Packages |
| --- | --- |
| `devtool` | ESLint, TypeScript, Turborepo, Lefthook, Jiti, and shared configs |
| `react` | React, React DOM, and their type packages |
| `tailwind` | Tailwind CSS |

Use catalog references instead of repeating versions:

```json
{
	"devDependencies": {
		"typescript": "catalog:devtool"
	}
}
```

`trustPolicy: no-downgrade` rejects packages whose newer release has weaker trust evidence than an earlier release. Review the package and its provenance before adding a temporary exception to `minimumReleaseAgeExclude`.

## Git hooks

Lefthook runs two pre-commit jobs in parallel:

1. `pnpm lint:fix` checks formatting and stages safe fixes.
2. `pnpm typecheck` runs when staged JavaScript or TypeScript files change.

Commits use the [Conventional Commits](https://www.conventionalcommits.org) format.

## Author

**monorepo-template** © [Xat](https://github.com/withxat). Authored and maintained by Xat with help from [contributors](https://github.com/withxat/monorepo-template/graphs/contributors).

[Blog](https://blog.xat.sh) · GitHub [@withxat](https://github.com/withxat) · Telegram [@withxat](https://t.me/withxat) · X [@withxat](https://x.com/withxat) · [i@xat.sh](mailto:i@xat.sh)
