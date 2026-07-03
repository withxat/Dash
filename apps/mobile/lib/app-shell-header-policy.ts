const TAB_NAMES = ['home', 'items', 'watchtower', 'search'] as const
type TabName = typeof TAB_NAMES[number]

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

export type AppShellHeaderPolicy
	= | { headerLargeTitle: boolean, kind: 'screen', title: string, usesAvatar: boolean }
		| { kind: 'preserve' }

function isFormSheetRoute(segments: readonly string[]): boolean {
	const tail = segments.at(-1)
	return tail != null && FORM_SHEET_TAIL.has(tail)
}

function isTabRootRoute(segments: readonly string[]): boolean {
	return segments.length === 3
		&& segments[1] === '(tabs)'
		&& TAB_NAMES.includes(segments[2] as TabName)
}

function titleForFeatureRoute(segments: readonly string[]): string {
	const group = segments[1]
	if (!group || group === '(tabs)')
		return ''

	const rootTitle = FEATURE_ROOT_TITLES[group]
	const tail = segments.at(-1) ?? ''
	const depth = segments.length - 2

	if (depth <= 1 && tail === 'index')
		return rootTitle ?? group

	if (depth === 2 && tail === 'index') {
		if (group === 'zones')
			return 'Zone'
		if (group === 'workers')
			return 'Worker'
		if (group === 'storage' && segments[2] === 'r2')
			return 'R2'
		if (group === 'storage' && segments[2] === 'kv')
			return 'KV'
		if (group === 'storage' && segments[2] === 'd1')
			return 'D1'
		if (group === 'storage' && segments[2] === 'queues')
			return 'Queues'
		if (group === 'storage' && segments[2] === 'secrets')
			return 'Secrets Store'
	}

	if (group === 'workers' && segments[2] === 'pages' && segments.length === 5)
		return 'Deployment'
	if (group === 'workers' && segments[2] === 'pages')
		return 'Pages'

	if (group === 'storage' && segments[2] === 'r2' && segments.length === 4)
		return 'Bucket'
	if (group === 'storage' && segments[2] === 'kv' && segments.length === 4)
		return 'Namespace'
	if (group === 'storage' && segments[2] === 'd1' && segments.length === 4)
		return 'Database'
	if (group === 'storage' && segments[2] === 'queues' && segments.length === 4)
		return 'Queue'
	if (group === 'storage' && segments[2] === 'secrets' && segments.length === 4)
		return 'Store'

	return LEAF_TITLES[tail] || rootTitle || group
}

/**
 * Header mode is stable per outer stack item: tab roots are always large and
 * pushed feature stacks are always compact. Nested form sheets preserve the
 * header underneath them instead of mutating its navigation item.
 */
export function appShellHeaderPolicy(segments: readonly string[]): AppShellHeaderPolicy {
	if (isFormSheetRoute(segments))
		return { kind: 'preserve' }

	if (isTabRootRoute(segments)) {
		const tab = segments[2] as TabName
		return {
			headerLargeTitle: true,
			kind: 'screen',
			title: TAB_TITLES[tab],
			usesAvatar: true,
		}
	}

	if (segments[1] === '(tabs)')
		return { kind: 'preserve' }

	if (!segments[1] || segments[1] === '(app)')
		return { kind: 'preserve' }

	return {
		headerLargeTitle: false,
		kind: 'screen',
		title: titleForFeatureRoute(segments),
		usesAvatar: false,
	}
}
