// Forecast V2 workspace Inertia page (slice C3).
//
// The top-level V2 React page rendered by `ForecastsController#show` (V2 path,
// slice C2) through the dedicated `forecast_inertia` layout. It receives the
// typed first-viewport props assembled by
// `Forecasts::WorkspaceLoading#forecast_v2_workspace_props` (one region per
// read model) and wires them into the workspace frame.
//
// State ownership (spec "State Ownership", "Frontend Runtime Modules"): this page
// stands up the ONE shared store (`useForecastWorkspace`) seeded from the props,
// then hands the shell + components their slices. The server owns canonical plan
// truth; this page owns only ephemeral interaction state. There are NO network
// requests on first paint — every region renders from preloaded props.
//
// Slices C4–C6 fill the chart, selected-period inspector, assumption groups, and
// issue panel. Slices C4–C5 have landed (chart + inspector); the remaining
// regions render as stable, keyed placeholders so the shell frame, region cache
// keys, and scoped-patch targets exist before C6 lands. Tokens only — no raw
// palette.

import { Head } from "@inertiajs/react";
import type { JSX } from "react";
import ForecastPlanShell from "../../forecast/components/ForecastPlanShell";
import MetricStrip, {
	metricsToStripEntries,
} from "../../forecast/components/MetricStrip";
import ProjectionChart from "../../forecast/components/ProjectionChart";
import SelectedPeriodInspector from "../../forecast/components/SelectedPeriodInspector";
import {
	FORECAST_REGIONS,
	useForecastWorkspace,
} from "../../forecast/hooks/useForecastWorkspace";
import { usePeriodPayloadCache } from "../../forecast/hooks/usePeriodPayloadCache";
import { ft } from "../../forecast/i18n";
import type { ForecastWorkspaceProps } from "../../forecast/types/readModels";

// A placeholder for a region a later slice fills (assumptions, issues). It still
// carries the stable region key + data-testid so the shell's scoped-patch targets
// and region cache keys exist now.
function RegionPlaceholder({
	regionKey,
	cacheKey,
	label,
}: {
	readonly regionKey: string;
	readonly cacheKey: string;
	readonly label: string;
}): JSX.Element {
	return (
		<section
			data-testid={regionKey}
			data-region={regionKey}
			data-cache-key={cacheKey}
			className="rounded-xl border border-primary border-dashed bg-container p-6 text-sm text-subdued"
		>
			{label}
		</section>
	);
}

export default function Workspace(props: ForecastWorkspaceProps): JSX.Element {
	const { plan, band, selectedPeriod, freshness } = props;
	const workspace = useForecastWorkspace(props);
	const cacheKeys = workspace.regionCacheKeys;

	// Serve the selected-period detail from the preloaded seed + local cache,
	// fetching GET /forecast/periods/:period_key only on a settled cache miss
	// (debounced). The workspace store reports SETTLED selections only, so chart
	// hover/scrub never reaches the network. A recompute changes
	// `cacheKeys.inspector`, which resets the cache so stale detail is never served.
	const period = usePeriodPayloadCache({
		selectedPeriodKey: workspace.selectedPeriodKey,
		seed: selectedPeriod,
		cacheKey: cacheKeys.inspector,
	});

	// The aligned metric strip tracks the served period (so it updates on
	// selection), falling back to the seed for the first paint.
	const metricsSource = period.payload ?? selectedPeriod;
	const metricEntries = metricsSource
		? metricsToStripEntries(metricsSource.metrics)
		: [];

	return (
		<>
			<Head title={`${plan.name} · ${ft("forecasts.workspace.title")}`} />

			<ForecastPlanShell plan={plan} workspace={workspace}>
				{/* Aligned metric strip for the selected period (privacy-safe values). */}
				<MetricStrip
					entries={metricEntries}
					regionKey={FORECAST_REGIONS.metricStrip}
				/>

				{/* Chart band (D3): the compact preloaded period index + selected marker
				    live in `band`; pointer/keyboard scrubbing is local-only and reports
				    settled selections to the shared store with zero network. */}
				<ProjectionChart
					band={band}
					selectedPeriodKey={workspace.selectedPeriodKey}
					onSelectPeriod={workspace.selectPeriod}
					regionKey={FORECAST_REGIONS.chart}
					cacheKey={cacheKeys.chart}
				/>

				<div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
					{/* Selected-period inspector (C5): metric strip detail, trace-backed
					    explanation lines, active assumption links, actual/projected
					    labels, and period issues. Served by usePeriodPayloadCache from the
					    preloaded seed + local cache; settled-selection cache misses fetch
					    the JSON read-model endpoint (debounced). */}
					<div className="lg:col-span-2">
						<SelectedPeriodInspector
							payload={period.payload}
							status={period.status}
							refresh={period.refresh}
							regionKey={FORECAST_REGIONS.inspector}
							cacheKey={cacheKeys.inspector}
						/>
					</div>

					{/* Assumption groups — filled by slice C6. */}
					<RegionPlaceholder
						regionKey={FORECAST_REGIONS.assumptions}
						cacheKey={cacheKeys.assumptions}
						label={`${props.assumptionGroups.groups.length} groups`}
					/>
				</div>

				{/* Issue panel — filled by slice C6. Freshness drives the recompute state. */}
				<RegionPlaceholder
					regionKey={FORECAST_REGIONS.issues}
					cacheKey={cacheKeys.issues}
					label={`${props.issues.length} issues · ${freshness.state}`}
				/>
			</ForecastPlanShell>
		</>
	);
}
