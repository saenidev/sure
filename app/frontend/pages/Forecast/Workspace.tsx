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
// issue panel. This page renders those as stable, keyed regions now so the shell
// frame, region cache keys, and scoped-patch targets exist before those slices
// land. Tokens only — no raw palette.

import { Head } from "@inertiajs/react";
import type { JSX } from "react";
import ForecastPlanShell from "../../forecast/components/ForecastPlanShell";
import MetricStrip, {
	metricsToStripEntries,
} from "../../forecast/components/MetricStrip";
import ProjectionChart from "../../forecast/components/ProjectionChart";
import {
	FORECAST_REGIONS,
	useForecastWorkspace,
} from "../../forecast/hooks/useForecastWorkspace";
import { ft } from "../../forecast/i18n";
import type { ForecastWorkspaceProps } from "../../forecast/types/readModels";

// A placeholder for a region a later slice fills (chart, inspector, assumptions,
// issues). It still carries the stable region key + data-testid so the shell's
// scoped-patch targets and region cache keys exist now.
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

	const metricEntries = selectedPeriod
		? metricsToStripEntries(selectedPeriod.metrics)
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
					{/* Selected-period inspector — filled by slice C5. */}
					<div className="lg:col-span-2">
						<RegionPlaceholder
							regionKey={FORECAST_REGIONS.inspector}
							cacheKey={cacheKeys.inspector}
							label={
								workspace.selectedPeriodKey ??
								ft("forecasts.workspace.no_period_selected")
							}
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
