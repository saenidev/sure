// Forecast V2 Inertia page (spike slice A4).
//
// Receives the typed read-model-shaped props from
// `ForecastV2SpikeController#show` and renders the first-viewport shell: the
// plan label, a freshness pill, and a placeholder for the local D3 scrub mock
// (built in slice A5). It uses only Sure design tokens (text-primary,
// bg-container, border-primary, etc.) and an inline SVG glyph — no raw palette
// colors. The user-facing plan + metric labels are localized server-side and
// passed through props; the spike formats the short freshness status token
// client-side (real i18n for the freshness lifecycle lands in Stage C).
//
// This module owns only ephemeral, first-viewport presentation. The local
// no-network scrub interaction state arrives in A5.

import { Head } from "@inertiajs/react";
import type { JSX } from "react";
import type {
	ForecastSpikeProps,
	FreshnessLifecycle,
} from "../../forecast/types/readModels";

// Map each freshness lifecycle state to the Sure status tokens used by the pill.
// These prefigure the Stage C `FreshnessIndicator` state styling. No raw palette
// colors — token classes only.
const FRESHNESS_TOKENS: Record<
	FreshnessLifecycle,
	{ dot: string; text: string }
> = {
	fresh: { dot: "bg-success", text: "text-success" },
	stale: { dot: "bg-warning", text: "text-warning" },
	recomputing: { dot: "bg-warning", text: "text-warning" },
	failed: { dot: "bg-destructive", text: "text-destructive" },
	"source-limited": { dot: "bg-warning", text: "text-warning" },
};

function formatFreshnessLabel(state: FreshnessLifecycle): string {
	// Turn the machine token into a readable status (e.g. "source-limited" ->
	// "Source limited"). Throwaway spike formatting; Stage C localizes this.
	const spaced = state.replace(/-/g, " ");
	return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

function formatProjectedAt(iso: string): string {
	const parsed = new Date(iso);
	if (Number.isNaN(parsed.getTime())) {
		return iso;
	}
	return parsed.toLocaleDateString(undefined, {
		year: "numeric",
		month: "short",
		day: "numeric",
	});
}

function FreshnessPill({
	freshness,
}: {
	freshness: ForecastSpikeProps["freshness"];
}): JSX.Element {
	const tokens = FRESHNESS_TOKENS[freshness.state] ?? FRESHNESS_TOKENS.stale;

	return (
		<span
			data-testid="forecast-freshness-pill"
			className="inline-flex items-center gap-2 rounded-full border border-primary bg-container px-3 py-1 text-sm font-medium"
		>
			<span
				aria-hidden="true"
				className={`size-2 rounded-full ${tokens.dot}`}
			/>
			<span className={tokens.text}>{formatFreshnessLabel(freshness.state)}</span>
			<span className="text-subdued">
				· as of {formatProjectedAt(freshness.projectedAt)}
			</span>
		</span>
	);
}

// Inline SVG glyph (an upward trend line) using currentColor — no raw palette
// colors, no lucide_icon dependency. Token text color drives the stroke.
function ProjectionGlyph(): JSX.Element {
	return (
		<svg
			aria-hidden="true"
			viewBox="0 0 24 24"
			fill="none"
			stroke="currentColor"
			strokeWidth="2"
			strokeLinecap="round"
			strokeLinejoin="round"
			className="size-5 text-secondary"
		>
			<path d="M3 17l6-6 4 4 8-8" />
			<path d="M17 7h4v4" />
		</svg>
	);
}

export default function Spike({
	plan,
	periodKeys,
	currentPeriodKey,
	series,
	freshness,
}: ForecastSpikeProps): JSX.Element {
	return (
		<div
			data-testid="forecast-spike-page"
			className="mx-auto flex h-full w-full max-w-5xl flex-col gap-6 p-6"
		>
			<Head title={plan.label} />

			<header className="flex flex-wrap items-center justify-between gap-4">
				<div className="flex items-center gap-3">
					<span className="flex size-10 items-center justify-center rounded-lg border border-primary bg-surface-inset">
						<ProjectionGlyph />
					</span>
					<div className="flex flex-col">
						<h1
							data-testid="forecast-plan-label"
							className="text-xl font-semibold text-primary"
						>
							{plan.label}
						</h1>
						<p className="text-sm text-secondary">
							{plan.currency} · v{plan.version}
						</p>
					</div>
				</div>

				<FreshnessPill freshness={freshness} />
			</header>

			{/* Placeholder for the local D3 scrub mock built in slice A5. It renders
			    the preloaded period series with zero-network pointer/keyboard period
			    selection. For now we surface the data contract the scrub will own so
			    the page is non-blank and the prop wiring is provable. */}
			<section
				data-testid="forecast-scrub-placeholder"
				aria-label="Projection scrub (placeholder)"
				className="flex flex-col gap-3 rounded-xl border border-primary bg-container p-5"
			>
				<div className="flex items-center justify-between gap-2">
					<h2 className="text-sm font-medium text-primary">Projection</h2>
					<span className="text-xs text-subdued">
						{periodKeys.length} periods · selected {currentPeriodKey}
					</span>
				</div>
				<div className="flex h-32 items-center justify-center rounded-lg border border-dashed border-primary bg-surface-inset">
					<span className="text-sm text-subdued">
						Scrub mock placeholder ({series.length} points) — A5
					</span>
				</div>
			</section>
		</div>
	);
}
