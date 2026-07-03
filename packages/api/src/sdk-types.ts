/**
 * REST resource types from the official `cloudflare` SDK (types only — no runtime import).
 * @see https://github.com/cloudflare/cloudflare-typescript
 */
import type { Account } from 'cloudflare/resources/accounts/accounts'
import type { CachePurgeParams } from 'cloudflare/resources/cache/cache'
import type { D1 } from 'cloudflare/resources/d1/d1'
import type { DatabaseListResponse, QueryResult } from 'cloudflare/resources/d1/database/database'
import type { RecordCreateParams, RecordResponse } from 'cloudflare/resources/dns/records'
import type { Address } from 'cloudflare/resources/email-routing/addresses'
import type { Settings as EmailRoutingSettingsResource } from 'cloudflare/resources/email-routing/email-routing'
import type { EmailRoutingRule as EmailRoutingRuleResource } from 'cloudflare/resources/email-routing/rules/rules'
import type { AccessRuleListResponse } from 'cloudflare/resources/firewall/access-rules'
import type { Healthcheck as HealthcheckResource } from 'cloudflare/resources/healthchecks/healthchecks'
import type { Image } from 'cloudflare/resources/images/v1/v1'
import type { Key } from 'cloudflare/resources/kv/namespaces/keys'
import type { Namespace } from 'cloudflare/resources/kv/namespaces/namespaces'
import type { LoadBalancer as LoadBalancerResource } from 'cloudflare/resources/load-balancers/load-balancers'
import type { Pool } from 'cloudflare/resources/load-balancers/pools/pools'
import type { PageRule as PageRuleResource } from 'cloudflare/resources/page-rules/page-rules'
import type { DomainListResponse as PagesDomainResource } from 'cloudflare/resources/pages/projects/domains'
import type {
	Deployment as PagesProjectDeployment,
	Project as PagesProjectResource,
} from 'cloudflare/resources/pages/projects/projects'
import type { Queue } from 'cloudflare/resources/queues/queues'
import type { Bucket } from 'cloudflare/resources/r2/buckets/buckets'
import type { ObjectListResponse } from 'cloudflare/resources/r2/buckets/objects'
import type { Domain as RegistrarDomainResource } from 'cloudflare/resources/registrar/domains'
import type { Site } from 'cloudflare/resources/rum/site-info'
import type { SecretListResponse } from 'cloudflare/resources/secrets-store/stores/secrets'
import type { StoreListResponse } from 'cloudflare/resources/secrets-store/stores/stores'
import type { CloudflareTunnel } from 'cloudflare/resources/shared'
import type { CertificatePackListResponse } from 'cloudflare/resources/ssl/certificate-packs/certificate-packs'
import type { UniversalSSLSettings } from 'cloudflare/resources/ssl/universal/settings'
import type { Video } from 'cloudflare/resources/stream/stream'
import type { WidgetListResponse } from 'cloudflare/resources/turnstile/widgets'
import type { TokenVerifyResponse } from 'cloudflare/resources/user/tokens/tokens'
import type { UserGetResponse } from 'cloudflare/resources/user/user'
import type { CreateIndex } from 'cloudflare/resources/vectorize/indexes/indexes'
import type { WaitingRoom as WaitingRoomResource } from 'cloudflare/resources/waiting-rooms/waiting-rooms'
import type { DomainListResponse } from 'cloudflare/resources/workers/domains'
import type { RouteListResponse } from 'cloudflare/resources/workers/routes'
import type { Deployment as WorkerScriptDeployment } from 'cloudflare/resources/workers/scripts/deployments'
import type { ScriptAndVersionSettingGetResponse } from 'cloudflare/resources/workers/scripts/script-and-version-settings'
import type { ScriptListResponse } from 'cloudflare/resources/workers/scripts/scripts'
import type { SubdomainGetResponse } from 'cloudflare/resources/workers/scripts/subdomain'
import type { ApplicationListResponse } from 'cloudflare/resources/zero-trust/access/applications/applications'
import type { SettingGetResponse } from 'cloudflare/resources/zones/settings'
import type { Zone } from 'cloudflare/resources/zones/zones'

export type CloudflareAccount = Account
export type CloudflareUser = UserGetResponse
export type TokenVerifyResult = TokenVerifyResponse

export type CloudflareZone = Zone
export type CloudflarePlan = Zone.Plan

export type DnsRecord = RecordResponse
/**
 * DNS record write body used by the app. Field names align with
 * `RecordCreateParams` in the SDK; `zone_id` is passed separately by the client.
 */
export type DnsRecordInput = {
	content: string
	priority?: number
	type: string
} & Pick<RecordCreateParams.ARecord, 'comment' | 'name' | 'proxied' | 'ttl'>

/** Body for POST /zones/:zone/purge_cache — `zone_id` is in the URL. */
export type PurgeCacheInput
	= | Omit<CachePurgeParams.CachePurgeEverything, 'zone_id'>
		| Omit<CachePurgeParams.CachePurgeFlexPurgeByHostnames, 'zone_id'>
		| Omit<CachePurgeParams.CachePurgeFlexPurgeByPrefixes, 'zone_id'>
		| Omit<CachePurgeParams.CachePurgeFlexPurgeByTags, 'zone_id'>
		| Omit<CachePurgeParams.CachePurgeSingleFile, 'zone_id'>

/** Zone settings that expose an editable `value` (excludes read-only entries like SSL recommender). */
export type ZoneSetting = Extract<SettingGetResponse, { value: unknown }>

export type CloudflareWorkerScript = ScriptListResponse
export type WorkerSubdomainStatus = SubdomainGetResponse
export type WorkerDomain = DomainListResponse
export type WorkerDeployment = WorkerScriptDeployment
export type WorkerRoute = RouteListResponse
export type WorkerScriptSettings = ScriptAndVersionSettingGetResponse

export type KvNamespace = Namespace
export type KvKey = Key

export type R2Bucket = Bucket
export type R2Object = ObjectListResponse

export type PagesProject = PagesProjectResource
export type PagesDeployment = PagesProjectDeployment
export type PagesDomain = PagesDomainResource

export type RumSite = Site

/** D1 database summary row (GET /accounts/:id/d1/database). */
export type D1DatabaseSummary = DatabaseListResponse
/** D1 database detail incl. file size and table count (GET …/d1/database/:uuid). */
export type D1Database = D1
/** One statement's result from POST …/d1/database/:uuid/query. */
export type D1QueryResult = QueryResult

/** A queue with its producers/consumers (GET /accounts/:id/queues). */
export type QueueSummary = Queue

/** A Vectorize index (GET /accounts/:id/vectorize/v2/indexes). */
export type VectorizeIndex = CreateIndex

/** A Secrets Store store (GET /accounts/:id/secrets_store/stores). */
export type SecretsStore = StoreListResponse
/** A secret's metadata — the value is never readable (GET …/stores/:store/secrets). */
export type SecretsStoreSecret = SecretListResponse

/** A Turnstile widget (GET /accounts/:id/challenges/widgets). */
export type TurnstileWidget = WidgetListResponse

/** An SSL certificate pack on a zone (GET /zones/:zone/ssl/certificate_packs). */
export type CertificatePack = CertificatePackListResponse
/** Universal SSL settings for a zone (GET /zones/:zone/ssl/universal/settings). */
export type UniversalSslSettings = UniversalSSLSettings

/** An IP Access Rule (GET /zones/:zone/firewall/access_rules/rules). */
export type IpAccessRule = AccessRuleListResponse
/** Mitigation applied by an IP Access Rule. */
export type IpAccessRuleMode = AccessRuleListResponse['mode']

/** A zone healthcheck (GET /zones/:zone/healthchecks). */
export type Healthcheck = HealthcheckResource

/** A zone waiting room (GET /zones/:zone/waiting_rooms). */
export type WaitingRoom = WaitingRoomResource

/** A zone load balancer (GET /zones/:zone/load_balancers). */
export type LoadBalancer = LoadBalancerResource
/** An account origin pool (GET /accounts/:id/load_balancers/pools). */
export type LoadBalancerPool = Pool

/** A zone page rule (GET /zones/:zone/pagerules). */
export type PageRule = PageRuleResource

/** A zone Email Routing rule (GET /zones/:zone/email/routing/rules). */
export type EmailRoutingRule = EmailRoutingRuleResource
/** An account Email Routing destination address (GET /accounts/:id/email/routing/addresses). */
export type EmailRoutingAddress = Address
/** Zone Email Routing status (GET /zones/:zone/email/routing). */
export type EmailRoutingSettings = EmailRoutingSettingsResource

/** A Registrar domain (GET /accounts/:id/registrar/domains). */
/** SDK type misses fields the API actually returns (`name`, `auto_renew`). */
export type RegistrarDomain = RegistrarDomainResource & { auto_renew?: boolean, name?: string }

/** A Cloudflare Tunnel (GET /accounts/:id/cfd_tunnel). */
export type Tunnel = CloudflareTunnel

/** A Zero Trust Access application (GET /accounts/:id/access/apps). */
export type AccessApplication = ApplicationListResponse

/** A Cloudflare Images image (GET /accounts/:id/images/v1). */
export type ImagesImage = Image

/** A Stream video (GET /accounts/:id/stream). */
export type StreamVideo = Video
