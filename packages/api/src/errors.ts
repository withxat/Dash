/** Error thrown when a Cloudflare API request fails. */
export class ApiError extends Error {
	readonly status: number
	readonly errors: Array<{ code: number, message: string }>
	constructor(status: number, errors: Array<{ code: number, message: string }>) {
		const summary = errors.map(e => `${e.code}: ${e.message}`).join('; ')
		super(summary || `HTTP ${status}`)
		this.name = 'ApiError'
		this.status = status
		this.errors = errors
	}
}
