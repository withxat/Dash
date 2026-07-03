import { Easing, FadeIn, FadeInDown, FadeInUp, FadeOut, FadeOutUp, LinearTransition } from 'react-native-reanimated'

const easing = Easing.out(Easing.cubic)

/** Shared layout transition for position/size changes (list reflow, collapsibles). */
export const layoutTransition = LinearTransition.duration(200).easing(easing)

/** Mount/unmount — subtle fade for list rows and sections. */
export const fadeIn = FadeIn.duration(180).easing(easing)
export const fadeOut = FadeOut.duration(120).easing(easing)

/** Toast and top-attached overlays. */
export const fadeInUp = FadeInUp.duration(200).easing(easing)
export const fadeOutUp = FadeOutUp.duration(150).easing(easing)

/** Expandable panel content (Collapsible, accordions). */
export const collapseIn = FadeInDown.duration(200).easing(easing)
export const collapseOut = FadeOutUp.duration(150).easing(easing)
