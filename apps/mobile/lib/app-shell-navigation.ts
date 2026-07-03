interface AppShellNavigation {
	getParent: () => AppShellNavigation | undefined
	getState: () => undefined | { routeNames?: readonly string[] }
	setOptions: (options: object) => void
}

/** App-stack navigator that owns the shared shell header. */
export function findAppShellNavigation(navigation: AppShellNavigation) {
	let nav: AppShellNavigation | undefined = navigation

	while (nav) {
		const routeNames = nav.getState()?.routeNames
		if (routeNames?.includes('(tabs)'))
			return nav
		nav = nav.getParent()
	}

	return navigation.getParent()
}
