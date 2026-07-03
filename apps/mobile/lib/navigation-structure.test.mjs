/* eslint-disable test/no-import-node-test -- This package uses Node's zero-dependency test runner. */
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const appRoot = new URL('../app/(app)/', import.meta.url)

async function source(path) {
	return readFile(new URL(path, appRoot), 'utf8')
}

test('native tabs do not own a shared stack header', async () => {
	const layout = await source('_layout.tsx')
	assert.match(layout, /<NativeTabs/)
	assert.doesNotMatch(layout, /appShellHeaderOptions|<Stack/)
})

test('every tab root owns its native stack header', async () => {
	for (const path of ['home/_layout.tsx', '(items)/_layout.tsx', 'watchtower/_layout.tsx', 'search/_layout.tsx']) {
		const layout = await source(path)
		assert.match(layout, /<Stack/)
		assert.match(layout, /tabRootScreenOptions/)
	}
})

test('item feature screens are flattened into the items stack', async () => {
	const layout = await source('(items)/_layout.tsx')
	assert.match(layout, /initialRouteName: 'items'/)
	assert.match(layout, /zones\/\[id\]\/record/)
	assert.match(layout, /storage\/r2-upload/)
})
