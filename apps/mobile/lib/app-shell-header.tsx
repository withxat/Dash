import type { Stack } from 'expo-router'
import type { ComponentProps } from 'react'

import type { TabName } from './tab-routes'
import type { ThemePalette } from './theme'

import { AccountAvatarHeaderButton } from '../components/account-avatar-header-button'
import { HeaderBackButton } from '../components/header-back-button'
import { avatarHeaderSlotStyle } from './avatar-header'
import { stackScreenOptions } from './navigation'
import { SCREEN_GUTTER } from './screen-gutter'
import { isTabRootSegment, TAB_NAMES } from './tab-routes'

type StackScreenOptions = NonNullable<ComponentProps<typeof Stack>['screenOptions']>

const TAB_TITLES: Record<TabName, string> = {
	home: 'Home',
	items: 'Items',
	search: 'Search',
	watchtower: 'Watchtower',
}

/** Routes that present a form sheet with its own native header. */
const FORM_SHEET_TAIL = new Set([
	'access-rule-new',
	'console',
	'edit-shortcuts',
	'event',
	'kv-entry',
	'namespace-edit',
	'new-bucket',
	'r2-object',
	'r2-upload',
	'record',
])

const FEATURE_ROOT_TITLES: Record<string, string> = {
	account: 'Account',
	profile: 'Profile',
	storage: 'Storage',
	workers: 'Workers & Pages',
	zones: 'Zones',
}

/** Nested screen titles keyed by the last pathname segment. */
const LEAF_TITLES: Record<string, string> = {
	'access-apps': 'Access apps',
	'access-rules': 'IP Access Rules',
	'analytics': 'Analytics',
	'builds': 'Builds',
	'cache': 'Cache',
	'console': 'SQL console',
	'd1': 'D1',
	'deployments': 'Deployments',
	'dns': 'DNS records',
	'domains': 'Custom domains',
	'email-addresses': 'Email addresses',
	'email-routing': 'Email Routing',
	'healthchecks': 'Healthchecks',
	'images': 'Images',
	'index': '',
	'kv': 'KV',
	'lb-pools': 'LB Pools',
	'load-balancers': 'Load Balancers',
	'logs': 'Logs',
	'page-rules': 'Page Rules',
	'queues': 'Queues',
	'r2': 'R2',
	'registrar': 'Registrar',
	'routes': 'Workers routes',
	'secrets': 'Secrets Store',
	'security': 'Security',
	'settings': 'Settings',
	'source': 'Source',
	'ssl': 'SSL/TLS',
	'stream': 'Stream',
	'tunnels': 'Tunnels',
	'turnstile': 'Turnstile',
	'vectorize': 'Vectorize',
	'waf': 'WAF rules',
	'waiting-rooms': 'Waiting Rooms',
}

function isFormSheetRoute(segments: readonly string[]): boolean {
	const tail = segments.at(-1)
	return tail != null && FORM_SHEET_TAIL.has(tail)
}

function backHeaderLeft() {
	return {
		headerBackVisible: false,
		headerLeft: () => <HeaderBackButton />,
		headerLeftContainerStyle: { paddingLeft: SCREEN_GUTTER },
	}
}

function avatarHeaderLeft() {
	return {
		headerBackVisible: false,
		headerLeft: () => <AccountAvatarHeaderButton />,
		headerLeftContainerStyle: {
			...avatarHeaderSlotStyle(),
			paddingLeft: SCREEN_GUTTER,
		},
	}
}

function titleForFeatureRoute(segments: readonly string[]): { headerLargeTitle: boolean, title: string } {
	const group = segments[1]
	if (!group || group === '(tabs)')
		return { headerLargeTitle: true, title: '' }

	const rootTitle = FEATURE_ROOT_TITLES[group]
	const tail = segments.at(-1) ?? ''
	const depth = segments.length - 2

	if (depth <= 1 && tail === 'index')
		return { headerLargeTitle: true, title: rootTitle ?? group }

	if (depth === 2 && tail === 'index') {
		if (group === 'zones')
			return { headerLargeTitle: false, title: 'Zone' }
		if (group === 'workers')
			return { headerLargeTitle: false, title: 'Worker' }
		if (group === 'storage' && segments[2] === 'r2')
			return { headerLargeTitle: false, title: 'R2' }
		if (group === 'storage' && segments[2] === 'kv')
			return { headerLargeTitle: false, title: 'KV' }
		if (group === 'storage' && segments[2] === 'd1')
			return { headerLargeTitle: false, title: 'D1' }
		if (group === 'storage' && segments[2] === 'queues')
			return { headerLargeTitle: false, title: 'Queues' }
		if (group === 'storage' && segments[2] === 'secrets')
			return { headerLargeTitle: false, title: 'Secrets Store' }
	}

	if (group === 'workers' && segments[2] === 'pages' && segments.length === 5)
		return { headerLargeTitle: false, title: 'Deployment' }
	if (group === 'workers' && segments[2] === 'pages')
		return { headerLargeTitle: false, title: 'Pages' }

	if (group === 'storage' && segments[2] === 'r2' && segments.length === 4)
		return { headerLargeTitle: false, title: 'Bucket' }
	if (group === 'storage' && segments[2] === 'kv' && segments.length === 4)
		return { headerLargeTitle: false, title: 'Namespace' }
	if (group === 'storage' && segments[2] === 'd1' && segments.length === 4)
		return { headerLargeTitle: false, title: 'Database' }
	if (group === 'storage' && segments[2] === 'queues' && segments.length === 4)
		return { headerLargeTitle: false, title: 'Queue' }
	if (group === 'storage' && segments[2] === 'secrets' && segments.length === 4)
		return { headerLargeTitle: false, title: 'Store' }

	const leafTitle = LEAF_TITLES[tail]
	if (leafTitle)
		return { headerLargeTitle: false, title: leafTitle }

	return { headerLargeTitle: false, title: rootTitle ?? group }
}

/** One native header for tabs + pushed feature stacks (avatar on tab roots, back elsewhere). */
export function appShellHeaderOptions(
	segments: readonly string[],
	theme: ThemePalette,
): StackScreenOptions {
	if (isFormSheetRoute(segments))
		return { headerShown: false }

	const base = stackScreenOptions(theme)

	if (isTabRootSegment(segments)) {
		const tab = segments[2] as TabName
		return {
			...base,
			...avatarHeaderLeft(),
			headerLargeTitle: tab !== 'search',
			title: TAB_TITLES[tab],
		}
	}

	if (segments[1] === '(tabs)')
		return { headerShown: false }

	if (!segments[1] || segments[1] === '(app)')
		return { headerShown: false }

	const { headerLargeTitle, title } = titleForFeatureRoute(segments)

	return {
		...base,
		...backHeaderLeft(),
		headerLargeTitle,
		title,
	}
}

export function isAppTabRoot(segments: readonly string[]): boolean {
	return isTabRootSegment(segments)
}

export function tabNameFromSegments(segments: readonly string[]): TabName | undefined {
	if (!isTabRootSegment(segments))
		return undefined
	const tab = segments[2]
	return TAB_NAMES.includes(tab as TabName) ? tab as TabName : undefined
}
