/* eslint-disable test/no-import-node-test -- This package uses Node's zero-dependency test runner. */
import assert from 'node:assert/strict'
import test from 'node:test'

import { appShellHeaderPolicy } from './app-shell-header-policy.ts'

test('keeps every tab route on one stable large-title mode', () => {
	for (const tab of ['home', 'items', 'watchtower', 'search']) {
		assert.deepEqual(
			appShellHeaderPolicy(['(app)', '(tabs)', tab]),
			{
				headerLargeTitle: true,
				kind: 'screen',
				title: tab === 'watchtower' ? 'Watchtower' : `${tab[0].toUpperCase()}${tab.slice(1)}`,
				usesAvatar: true,
			},
		)
	}
})

test('keeps pushed feature stacks compact at every nested depth', () => {
	for (const segments of [
		['(app)', 'zones', 'index'],
		['(app)', 'zones', 'zone-id', 'index'],
		['(app)', 'zones', 'zone-id', 'dns'],
		['(app)', 'storage', 'r2', 'bucket-name'],
	]) {
		const policy = appShellHeaderPolicy(segments)
		assert.equal(policy.kind, 'screen')
		assert.equal(policy.headerLargeTitle, false)
		assert.equal(policy.usesAvatar, false)
	}
})

test('does not mutate the underlying header while a nested sheet is open', () => {
	assert.deepEqual(
		appShellHeaderPolicy(['(app)', '(tabs)', 'home', 'edit-shortcuts']),
		{ kind: 'preserve' },
	)
	assert.deepEqual(
		appShellHeaderPolicy(['(app)', 'zones', 'zone-id', 'record']),
		{ kind: 'preserve' },
	)
})
