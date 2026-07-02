const { getDefaultConfig } = require('expo/metro-config')
const { withNativeWind } = require('nativewind/metro')
const path = require('node:path')

const projectRoot = __dirname
const monorepoRoot = path.resolve(projectRoot, '..', '..')

const config = getDefaultConfig(projectRoot)

// Let Metro see the whole monorepo (packages/api, etc.) and resolve from the
// hoisted root node_modules (node-linker=hoisted in .npmrc).
config.watchFolders = [monorepoRoot]
config.resolver.nodeModulesPaths = [
	path.resolve(projectRoot, 'node_modules'),
	path.resolve(monorepoRoot, 'node_modules'),
]
config.resolver.disableHierarchicalLookup = true

module.exports = withNativeWind(config, { input: './global.css' })
