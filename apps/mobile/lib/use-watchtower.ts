import type {
	CertificatePack,
	CloudflareZone,
	Healthcheck,
	LoadBalancerPool,
	NotificationHistoryEntry,
	PagesProject,
	RegistrarDomain,
	Tunnel,
} from '@cloudfx/api'
import type { Href } from 'expo-router'

import { useQueries, useQuery } from '@tanstack/react-query'
import { useCallback, useMemo } from 'react'

import { cloudflareClient } from './api'
import { isForbidden } from './api-errors'
import { useActiveAccount } from './use-active-account'

/** How many zones the per-zone checks (certificates, healthchecks) fan out to. */
const ZONE_FANOUT_LIMIT = 10
/** Days before an expiry date turns the signal yellow. */
const EXPIRY_WARNING_DAYS = 30
/** Days before an expiry date turns the signal red. */
const EXPIRY_CRITICAL_DAYS = 7

export type WatchtowerStatus = 'critical' | 'ok' | 'warning'

/** One health check, normalized: what it is, how it's doing, where to act on it. */
export interface WatchtowerSignal {
	detail: string
	href: Href
	id: string
	status: WatchtowerStatus
	title: string
}

export interface WatchtowerSummary {
	critical: number
	ok: number
	warning: number
}

export type WatchtowerAlertsStatus = 'error' | 'loading' | 'ok' | 'unavailable'

export interface WatchtowerResult {
	alerts: NotificationHistoryEntry[]
	alertsStatus: WatchtowerAlertsStatus
	isLoading: boolean
	refetchAll: () => Promise<void>
	signals: WatchtowerSignal[]
	summary: WatchtowerSummary
	/** Checks hidden because the query failed (usually a missing OAuth scope). */
	unavailableCount: number
}

function plural(n: number, noun: string): string {
	return `${n} ${noun}${n === 1 ? '' : 's'}`
}

/** Whole days from now until `iso`; negative when already past. */
function daysUntil(iso?: null | string): number | undefined {
	if (!iso)
		return undefined
	const t = new Date(iso).getTime()
	if (Number.isNaN(t))
		return undefined
	return Math.floor((t - Date.now()) / 86_400_000)
}

function worstStatus(statuses: WatchtowerStatus[]): WatchtowerStatus {
	if (statuses.includes('critical'))
		return 'critical'
	if (statuses.includes('warning'))
		return 'warning'
	return 'ok'
}

function zonesSignal(zones: CloudflareZone[]): null | WatchtowerSignal {
	if (zones.length === 0)
		return null
	const inactive = zones.filter(zone => zone.status && zone.status !== 'active')
	return {
		detail: inactive.length > 0
			? `${plural(inactive.length, 'zone')} not active`
			: `All ${plural(zones.length, 'zone')} active`,
		href: '/zones',
		id: 'zones',
		status: inactive.length > 0 ? 'warning' : 'ok',
		title: 'Zones',
	}
}

function tunnelsSignal(tunnels: Tunnel[]): null | WatchtowerSignal {
	if (tunnels.length === 0)
		return null
	const down = tunnels.filter(t => t.status === 'down').length
	const degraded = tunnels.filter(t => t.status === 'degraded').length
	const inactive = tunnels.filter(t => t.status === 'inactive').length
	const detail = down > 0
		? `${plural(down, 'tunnel')} down`
		: degraded > 0
			? `${plural(degraded, 'tunnel')} degraded`
			: inactive > 0
				? `${tunnels.length - inactive} healthy · ${inactive} inactive`
				: `All ${plural(tunnels.length, 'tunnel')} healthy`
	return {
		detail,
		href: '/account/tunnels',
		id: 'tunnels',
		status: down > 0 ? 'critical' : degraded > 0 ? 'warning' : 'ok',
		title: 'Tunnels',
	}
}

function poolsSignal(pools: LoadBalancerPool[]): null | WatchtowerSignal {
	if (pools.length === 0)
		return null
	const disabled = pools.filter(pool => pool.enabled === false).length
	return {
		detail: disabled > 0
			? `${plural(disabled, 'pool')} disabled`
			: `All ${plural(pools.length, 'pool')} enabled`,
		href: '/account/lb-pools',
		id: 'lb-pools',
		status: disabled > 0 ? 'warning' : 'ok',
		title: 'LB Pools',
	}
}

function registrarSignal(domains: RegistrarDomain[]): null | WatchtowerSignal {
	if (domains.length === 0)
		return null
	const withExpiry = domains
		.map(domain => ({ days: daysUntil(domain.expires_at), domain }))
		.filter((entry): entry is { days: number, domain: RegistrarDomain } => entry.days != null)
		.sort((a, b) => a.days - b.days)
	const worst = withExpiry[0]
	const name = worst?.domain.name ?? worst?.domain.id ?? 'A domain'
	let status: WatchtowerStatus = 'ok'
	let detail = plural(domains.length, 'registered domain')
	if (worst) {
		if (worst.days < 0) {
			status = 'critical'
			detail = `${name} has expired`
		}
		else if (worst.days <= EXPIRY_CRITICAL_DAYS) {
			status = 'critical'
			detail = `${name} expires in ${plural(worst.days, 'day')}`
		}
		else if (worst.days <= EXPIRY_WARNING_DAYS) {
			status = 'warning'
			detail = `${name} expires in ${plural(worst.days, 'day')}`
		}
		else {
			detail = `Next renewal in ${plural(worst.days, 'day')}`
		}
	}
	return {
		detail,
		href: '/account/registrar',
		id: 'registrar',
		status,
		title: 'Registrar',
	}
}

interface ZoneScopedItems<T> {
	items: T[]
	zone: CloudflareZone
}

function certPackProblem(pack: CertificatePack): null | { desc: string, status: WatchtowerStatus } {
	const status = pack.status
	if (status.includes('failed') || status.includes('deleted') || status.includes('timed_out'))
		return { desc: 'certificate pack failed', status: 'critical' }
	if (status.startsWith('pending') || status === 'initializing')
		return { desc: 'certificate pack pending', status: 'warning' }
	const days = daysUntil(pack.certificates?.[0]?.expires_on)
	if (days != null && days < 0)
		return { desc: 'certificate expired', status: 'critical' }
	if (days != null && days <= EXPIRY_CRITICAL_DAYS)
		return { desc: `certificate expires in ${plural(days, 'day')}`, status: 'critical' }
	if (days != null && days <= EXPIRY_WARNING_DAYS)
		return { desc: `certificate expires in ${plural(days, 'day')}`, status: 'warning' }
	return null
}

function certsSignal(entries: Array<ZoneScopedItems<CertificatePack>>, truncated: boolean): null | WatchtowerSignal {
	const total = entries.reduce((sum, entry) => sum + entry.items.length, 0)
	if (total === 0)
		return null
	let firstProblem: undefined | { desc: string, status: WatchtowerStatus, zone: CloudflareZone }
	const statuses: WatchtowerStatus[] = []
	for (const entry of entries) {
		for (const pack of entry.items) {
			const problem = certPackProblem(pack)
			if (!problem)
				continue
			statuses.push(problem.status)
			if (!firstProblem || (problem.status === 'critical' && firstProblem.status !== 'critical'))
				firstProblem = { ...problem, zone: entry.zone }
		}
	}
	const suffix = truncated ? ` · first ${ZONE_FANOUT_LIMIT} zones` : ''
	return {
		detail: firstProblem
			? `${firstProblem.zone.name ?? firstProblem.zone.id}: ${firstProblem.desc}${suffix}`
			: `${plural(total, 'certificate pack')} healthy${suffix}`,
		href: firstProblem ? `/zones/${firstProblem.zone.id}/ssl` : '/zones',
		id: 'certificates',
		status: worstStatus(statuses),
		title: 'SSL certificates',
	}
}

function healthchecksSignal(entries: Array<ZoneScopedItems<Healthcheck>>, truncated: boolean): null | WatchtowerSignal {
	const total = entries.reduce((sum, entry) => sum + entry.items.length, 0)
	if (total === 0)
		return null
	let firstProblem: undefined | { check: Healthcheck, status: WatchtowerStatus, zone: CloudflareZone }
	const statuses: WatchtowerStatus[] = []
	for (const entry of entries) {
		for (const check of entry.items) {
			const status: null | WatchtowerStatus = check.status === 'unhealthy'
				? 'critical'
				: check.status === 'suspended' ? 'warning' : null
			if (!status)
				continue
			statuses.push(status)
			if (!firstProblem || (status === 'critical' && firstProblem.status !== 'critical'))
				firstProblem = { check, status, zone: entry.zone }
		}
	}
	const suffix = truncated ? ` · first ${ZONE_FANOUT_LIMIT} zones` : ''
	return {
		detail: firstProblem
			? `${firstProblem.check.name ?? 'A healthcheck'} ${firstProblem.check.status} (${firstProblem.zone.name ?? firstProblem.zone.id})`
			: `All ${plural(total, 'healthcheck')} healthy${suffix}`,
		href: firstProblem ? `/zones/${firstProblem.zone.id}/healthchecks` : '/zones',
		id: 'healthchecks',
		status: worstStatus(statuses),
		title: 'Healthchecks',
	}
}

function pagesSignal(projects: PagesProject[]): null | WatchtowerSignal {
	if (projects.length === 0)
		return null
	const failed = projects.filter(project => project.latest_deployment?.latest_stage?.status === 'failure')
	const first = failed[0]
	return {
		detail: first
			? `${first.name ?? 'A project'}: latest deployment failed`
			: `All ${plural(projects.length, 'project')} deployed`,
		href: first?.name ? `/workers/pages/${encodeURIComponent(first.name)}` : '/workers',
		id: 'pages',
		status: failed.length > 0 ? 'warning' : 'ok',
		title: 'Pages deployments',
	}
}

/**
 * Aggregates account-wide health signals for the Watchtower tab: zone status,
 * tunnels, LB pools, registrar renewals, SSL certificates, healthchecks, and
 * Pages deployments. Checks whose query fails (e.g. missing OAuth scope) are
 * counted as unavailable and omitted from the signal list.
 */
export function useWatchtower(): WatchtowerResult {
	const { activeAccountId } = useActiveAccount()
	const accountId = activeAccountId ?? undefined

	const zonesQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listZones({ accountId: accountId!, perPage: 50 }).then(p => p.items),
		queryKey: ['cf', 'zones-watchtower', accountId],
		retry: false,
	})
	const tunnelsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listTunnels(accountId!),
		queryKey: ['cf', 'account', accountId, 'tunnels'],
		retry: false,
	})
	const poolsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listLoadBalancerPools(accountId!),
		queryKey: ['cf', 'account', accountId, 'lb-pools'],
		retry: false,
	})
	const registrarQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listRegistrarDomains(accountId!),
		queryKey: ['cf', 'account', accountId, 'registrar-domains'],
		retry: false,
	})
	const pagesQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listPagesProjects(accountId!),
		queryKey: ['cf', 'pages-projects', accountId],
		retry: false,
	})
	const alertsQuery = useQuery({
		enabled: Boolean(accountId),
		queryFn: () => cloudflareClient.listNotificationHistory(accountId!, { perPage: 10 }),
		queryKey: ['cf', 'notification-history', accountId],
		retry: false,
	})

	const zones = useMemo(() => zonesQuery.data ?? [], [zonesQuery.data])
	const scopedZones = useMemo(() => zones.slice(0, ZONE_FANOUT_LIMIT), [zones])
	const zonesTruncated = zones.length > ZONE_FANOUT_LIMIT

	const certQueries = useQueries({
		queries: scopedZones.map(zone => ({
			queryFn: () => cloudflareClient.listCertificatePacks(zone.id),
			queryKey: ['cf', 'zone', zone.id, 'certificate-packs'],
			retry: false,
		})),
	})
	const checkQueries = useQueries({
		queries: scopedZones.map(zone => ({
			queryFn: () => cloudflareClient.listHealthchecks(zone.id),
			queryKey: ['cf', 'zone', zone.id, 'healthchecks'],
			retry: false,
		})),
	})

	const isLoading = zonesQuery.isLoading
		|| tunnelsQuery.isLoading
		|| poolsQuery.isLoading
		|| registrarQuery.isLoading
		|| pagesQuery.isLoading
		|| certQueries.some(q => q.isLoading)
		|| checkQueries.some(q => q.isLoading)

	const { signals, unavailableCount } = useMemo(() => {
		const collected: WatchtowerSignal[] = []
		let unavailable = 0

		const push = (signal: null | WatchtowerSignal) => {
			if (signal)
				collected.push(signal)
		}

		if (zonesQuery.isError)
			unavailable += 1
		else if (zonesQuery.data)
			push(zonesSignal(zonesQuery.data))

		if (tunnelsQuery.isError)
			unavailable += 1
		else if (tunnelsQuery.data)
			push(tunnelsSignal(tunnelsQuery.data))

		if (poolsQuery.isError)
			unavailable += 1
		else if (poolsQuery.data)
			push(poolsSignal(poolsQuery.data))

		if (registrarQuery.isError)
			unavailable += 1
		else if (registrarQuery.data)
			push(registrarSignal(registrarQuery.data))

		if (pagesQuery.isError)
			unavailable += 1
		else if (pagesQuery.data)
			push(pagesSignal(pagesQuery.data))

		const collectZoneScoped = <T>(queries: Array<{ data?: T[], isError: boolean }>): Array<ZoneScopedItems<T>> =>
			queries.flatMap((query, index) => {
				const zone = scopedZones[index]
				return zone && query.data ? [{ items: query.data, zone }] : []
			})

		if (scopedZones.length > 0) {
			if (certQueries.length > 0 && certQueries.every(q => q.isError))
				unavailable += 1
			else
				push(certsSignal(collectZoneScoped(certQueries), zonesTruncated))

			if (checkQueries.length > 0 && checkQueries.every(q => q.isError))
				unavailable += 1
			else
				push(healthchecksSignal(collectZoneScoped(checkQueries), zonesTruncated))
		}

		return { signals: collected, unavailableCount: unavailable }
	}, [
		certQueries,
		checkQueries,
		pagesQuery.data,
		pagesQuery.isError,
		poolsQuery.data,
		poolsQuery.isError,
		registrarQuery.data,
		registrarQuery.isError,
		scopedZones,
		tunnelsQuery.data,
		tunnelsQuery.isError,
		zonesQuery.data,
		zonesQuery.isError,
		zonesTruncated,
	])

	const summary = useMemo<WatchtowerSummary>(() => ({
		critical: signals.filter(s => s.status === 'critical').length,
		ok: signals.filter(s => s.status === 'ok').length,
		warning: signals.filter(s => s.status === 'warning').length,
	}), [signals])

	const alertsStatus: WatchtowerAlertsStatus = alertsQuery.isLoading
		? 'loading'
		: alertsQuery.isError
			? isForbidden(alertsQuery.error) ? 'unavailable' : 'error'
			: 'ok'

	const refetchAll = useCallback(async () => {
		await Promise.allSettled([
			zonesQuery.refetch(),
			tunnelsQuery.refetch(),
			poolsQuery.refetch(),
			registrarQuery.refetch(),
			pagesQuery.refetch(),
			alertsQuery.refetch(),
			...certQueries.map(q => q.refetch()),
			...checkQueries.map(q => q.refetch()),
		])
	}, [alertsQuery, certQueries, checkQueries, pagesQuery, poolsQuery, registrarQuery, tunnelsQuery, zonesQuery])

	return {
		alerts: alertsQuery.data ?? [],
		alertsStatus,
		isLoading,
		refetchAll,
		signals,
		summary,
		unavailableCount,
	}
}
