import type { MotionValue, Variants } from 'motion/react'
import type { ReactNode } from 'react'

import { motion, useReducedMotion, useScroll, useTransform } from 'motion/react'
import { createContext, use, useRef } from 'react'

// One easing curve for the whole site, matching the slow-in / fast-out feel the
// iOS app uses for its own transitions. Do not introduce a second curve.
const EASE = [0.16, 1, 0.3, 1] as const
const DURATION = 0.62

const group: Variants = {
	hidden: {},
	visible: { transition: { staggerChildren: 0.07 } },
}

/**
 * Below the fold, where a fade costs nothing: the element is off screen until
 * the reveal runs, so there is no paint to delay.
 */
const viewItem: Variants = {
	hidden: { opacity: 0, y: 18 },
	visible: { opacity: 1, transition: { duration: DURATION, ease: EASE }, y: 0 },
}

/**
 * Above the fold this settles into place without ever being transparent. An
 * `opacity: 0` hero headline is not painted, so it would push out Largest
 * Contentful Paint by the length of its own entrance.
 */
const loadItem: Variants = {
	hidden: { y: 14 },
	visible: { transition: { duration: DURATION, ease: EASE }, y: 0 },
}

const LoadContext = createContext(false)

interface RevealProps {
	children: ReactNode
	className?: string
	delay?: number
}

/**
 * One-shot entrance for a single block as it scrolls into view. Use when the
 * block has no children that need sequencing.
 */
export function Reveal({ children, className, delay = 0 }: RevealProps) {
	const reduceMotion = useReducedMotion()

	return (
		<motion.div
			className={className}
			initial={reduceMotion ? false : { opacity: 0, y: 18 }}
			transition={{ delay, duration: DURATION, ease: EASE }}
			viewport={{ amount: 0.25, once: true }}
			whileInView={{ opacity: 1, y: 0 }}
		>
			{children}
		</motion.div>
	)
}

interface StaggerProps {
	children: ReactNode
	className?: string
	/** `load` for above-the-fold content, `view` for anything below it. */
	on?: 'load' | 'view'
}

/**
 * Sequences its `StaggerItem` children so a group reads in the order it should
 * be understood. The parent and its items must live in the same tree for
 * `staggerChildren` to resolve.
 */
export function Stagger({ children, className, on = 'view' }: StaggerProps) {
	const reduceMotion = useReducedMotion()
	const initial = reduceMotion ? false : 'hidden'

	if (on === 'load') {
		return (
			<LoadContext value>
				<motion.div animate="visible" className={className} initial={initial} variants={group}>
					{children}
				</motion.div>
			</LoadContext>
		)
	}

	return (
		<motion.div
			className={className}
			initial={initial}
			variants={group}
			viewport={{ amount: 0.2, once: true }}
			whileInView="visible"
		>
			{children}
		</motion.div>
	)
}

export function StaggerItem({ children, className }: { children: ReactNode, className?: string }) {
	const reduceMotion = useReducedMotion()
	const onLoad = use(LoadContext)

	return (
		<motion.div className={className} variants={reduceMotion ? undefined : (onLoad ? loadItem : viewItem)}>
			{children}
		</motion.div>
	)
}

export interface TourStop {
	content: ReactNode
	id: string
	media: ReactNode
}

/**
 * One device held still while the surfaces inside it change. The pin is the
 * argument: the product is a single compact app, not four separate screens, and
 * a reader who scrolls the copy watches the same phone answer each claim.
 *
 * Built on CSS `position: sticky` rather than a scroll-hijacking pin, so it
 * cannot desynchronise from the scrollbar or strand the reader mid-section.
 * Below `lg` it degrades to a plain stacked list with each capture inline.
 */
export function StickyTour({ stops }: { stops: TourStop[] }) {
	const targetRef = useRef<HTMLDivElement>(null)
	const { scrollYProgress } = useScroll({
		offset: ['start start', 'end end'],
		target: targetRef,
	})

	return (
		<div ref={targetRef}>
			<div className="
				grid gap-16
				lg:grid-cols-12 lg:gap-x-10
			"
			>
				<div className="lg:col-span-5">
					{stops.map((stop, index) => (
						<div
							className="
								flex flex-col justify-center
								lg:min-h-[78vh]
							"
							key={stop.id}
						>
							<Reveal>{stop.content}</Reveal>
							{/* Compact screens get the capture inline: there is no room
							    beside the copy to hold a device still. */}
							<div className="
								mt-10
								lg:hidden
							"
							>
								{stop.media}
							</div>
							{index < stops.length - 1 && (
								<div className="
									mt-16 border-t border-kumo-hairline
									lg:hidden
								"
								/>
							)}
						</div>
					))}
				</div>

				<div className="
					hidden
					lg:col-span-6 lg:col-start-7 lg:block
				"
				>
					<div className="sticky top-24 flex h-[78vh] items-center justify-center">
						<div className="relative w-full max-w-80">
							{stops.map((stop, index) => (
								<TourMedia
									count={stops.length}
									index={index}
									key={stop.id}
									progress={scrollYProgress}
								>
									{stop.media}
								</TourMedia>
							))}
						</div>
					</div>
				</div>
			</div>
		</div>
	)
}

function TourMedia({
	children,
	count,
	index,
	progress,
}: {
	children: ReactNode
	count: number
	index: number
	progress: MotionValue<number>
}) {
	const reduceMotion = useReducedMotion()
	const step = 1 / count
	const start = index * step
	const fade = step * 0.3
	const isFirst = index === 0
	const isLast = index === count - 1

	// Keyframe offsets must stay inside [0,1] and never decrease, so the first
	// and last stops are open-ended rather than fading in from before the
	// section starts or out after it ends. The first capture also owns the frame
	// on the way in, otherwise the device reads as empty until you scroll.
	const input: number[] = []
	const opacityOut: number[] = []
	const scaleOut: number[] = []

	if (isFirst) {
		input.push(0)
		opacityOut.push(1)
		scaleOut.push(1)
	}
	else {
		input.push(start - fade, start + fade)
		opacityOut.push(0, 1)
		scaleOut.push(0.97, 1)
	}

	if (isLast) {
		input.push(1)
		opacityOut.push(1)
		scaleOut.push(1)
	}
	else {
		input.push(start + step - fade, start + step + fade)
		opacityOut.push(1, 0)
		scaleOut.push(1, 0.97)
	}

	const opacity = useTransform(progress, input, opacityOut)
	const scale = useTransform(progress, input, scaleOut)

	const idle = isFirst ? 1 : 0

	return (
		<motion.div
			className={index === 0 ? 'relative' : 'absolute inset-0'}
			style={reduceMotion ? { opacity: idle } : { opacity, scale }}
		>
			{children}
		</motion.div>
	)
}

interface ParallaxProps {
	children: ReactNode
	className?: string
	/**
	 * Travel in pixels across the full pass through the viewport. Give paired
	 * captures different depths so they read as a space rather than a flat row.
	 */
	depth?: number
}

/**
 * Scroll-linked vertical offset. The value stays on a motion value and never
 * touches React state, so scrolling costs no re-renders.
 */
export function Parallax({ children, className, depth = 40 }: ParallaxProps) {
	const targetRef = useRef<HTMLDivElement>(null)
	const reduceMotion = useReducedMotion()
	const { scrollYProgress } = useScroll({
		offset: ['start end', 'end start'],
		target: targetRef,
	})
	const y = useTransform(scrollYProgress, [0, 1], [depth, -depth])

	return (
		<div className={className} ref={targetRef}>
			<motion.div style={reduceMotion ? undefined : { y }}>
				{children}
			</motion.div>
		</div>
	)
}
