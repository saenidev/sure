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
// issue panel. With C6 landed, every first-viewport region renders its real
// component from preloaded props — no per-region fetch on first paint. Tokens
// only — no raw palette.

import { Head } from "@inertiajs/react";
import { type JSX, useCallback, useState } from "react";
import AssumptionEditor from "../../forecast/components/AssumptionEditor";
import AssumptionGroup from "../../forecast/components/AssumptionGroup";
import ForecastPlanShell from "../../forecast/components/ForecastPlanShell";
import IssuePanel from "../../forecast/components/IssuePanel";
import MetricStrip, {
	metricsToStripEntries,
} from "../../forecast/components/MetricStrip";
import ProjectionChart from "../../forecast/components/ProjectionChart";
import SelectedPeriodInspector from "../../forecast/components/SelectedPeriodInspector";
import { useAssumptionEditor } from "../../forecast/hooks/useAssumptionEditor";
import {
	FORECAST_REGIONS,
	useForecastWorkspace,
} from "../../forecast/hooks/useForecastWorkspace";
import { usePeriodPayloadCache } from "../../forecast/hooks/usePeriodPayloadCache";
import { ft } from "../../forecast/i18n";
import type {
	AssumptionGroupReadModel,
	ForecastWorkspaceProps,
	SavedAssumptionPatch,
} from "../../forecast/types/readModels";

// The assumption rail: the stable region the shell scopes for patches, holding
// one AssumptionGroup per kind (or a single empty state). Each group reads its
// preloaded card payloads from `AssumptionGroupReadModel` — no per-card fetch.
function AssumptionRail({
	assumptionGroups,
	regionKey,
	cacheKey,
	onEditCard,
}: {
	readonly assumptionGroups: AssumptionGroupReadModel;
	readonly regionKey: string;
	readonly cacheKey: string;
	/** Opens the typed editor drawer for a card (slice C7). */
	readonly onEditCard?: (cardId: string) => void;
}): JSX.Element {
	const { groups } = assumptionGroups;
	return (
		<section
			data-testid={regionKey}
			data-region={regionKey}
			data-cache-key={cacheKey}
			aria-label={ft("forecasts.assumptions.title")}
			className="flex flex-col gap-3"
		>
			{groups.length === 0 ? (
				<p className="rounded-xl border border-primary bg-container p-6 text-sm text-subdued">
					{ft("forecasts.assumptions.empty")}
				</p>
			) : (
				groups.map((group) => (
					<AssumptionGroup
						key={group.kind}
						group={group}
						onEditCard={onEditCard}
					/>
				))
			)}
		</section>
	);
}

// Folds a committed save's `saved_card` into the assumption groups, replacing the
// card with the matching id (or, if the assumption changed group, moving it).
// Other cards are untouched — a save patches only its scoped card region, never the
// whole rail (spec "Patch budget"). Groups whose cards all moved away are dropped.
function applySavedCard(
	groups: AssumptionGroupReadModel,
	patch: SavedAssumptionPatch,
): AssumptionGroupReadModel {
	const savedCard = patch.saved_card;
	if (!savedCard) {
		return groups;
	}

	const nextGroups = groups.groups
		.map((group) => ({
			...group,
			cards: group.cards.map((card) =>
				card.id === savedCard.id ? savedCard : card,
			),
		}))
		.filter((group) => group.cards.length > 0);

	return { ...groups, groups: nextGroups };
}

export default function Workspace(props: ForecastWorkspaceProps): JSX.Element {
	const { plan, band, selectedPeriod } = props;
	const workspace = useForecastWorkspace(props);
	const cacheKeys = workspace.regionCacheKeys;

	// The assumption rail reflects SERVER truth: it starts from the preloaded props
	// and is patched in place when a save commits (the saved card replaces its prior
	// version). The shared store owns version tokens + freshness; this owns only the
	// scoped card region the save patches.
	const [assumptionGroups, setAssumptionGroups] =
		useState<AssumptionGroupReadModel>(props.assumptionGroups);

	// The typed editor drawer (slice C7): opens from an assumption card and
	// composes the salary form. Opening fetches GET /forecast/assumptions/:id/edit
	// for one EditorPrefillReadModel; it owns NONE of plan/period/scenario state
	// (those stay in `workspace`), so opening/closing the drawer preserves the
	// selected period + scenario stack. The PATCH save is driven from the drawer
	// (slice C8) and its changed-region patch is folded in by `handleSaved` below.
	const editor = useAssumptionEditor();

	// Fold a committed save's typed changed-region patch (slice C8) into the
	// workspace WITHOUT a full reload: the shared store takes the new plan version +
	// scenario stack + freshness (recomputing -> fresh), which recompute the scoped
	// region cache keys, and the saved card replaces its prior version in the rail.
	// The selected-period inspector + metric strip re-derive from the new cache keys
	// via usePeriodPayloadCache. No region outside the patch is touched.
	const handleSaved = useCallback(
		(patch: SavedAssumptionPatch): void => {
			workspace.applyAssumptionPatch(patch);
			setAssumptionGroups((groups) => applySavedCard(groups, patch));
		},
		[workspace],
	);

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

					{/* Assumption rail (C6): kind-grouped, scannable assumption cards
					    that read like financial-planning language. Every card payload is
					    preloaded by AssumptionGroupReadModel — no per-card fetch. */}
					<AssumptionRail
						assumptionGroups={assumptionGroups}
						regionKey={FORECAST_REGIONS.assumptions}
						cacheKey={cacheKeys.assumptions}
						onEditCard={(cardId) =>
							editor.open({
								assumptionId: cardId,
								invokerId: `forecast-assumption-edit-${cardId}`,
							})
						}
					/>
				</div>

				{/* Issue panel (C6): recoverable plan/source issues with impact +
				    remediation actions, privacy-safe (no raw UUIDs). Freshness drives
				    the workspace recompute state separately. */}
				<IssuePanel
					issues={props.issues}
					regionKey={FORECAST_REGIONS.issues}
					cacheKey={cacheKeys.issues}
				/>
			</ForecastPlanShell>

			{/* Typed editor drawer (C7): the only interactive editor in the MVP is the
			    salary form. It renders OVER the workspace, so opening/closing preserves
			    the selected period + scenario stack. Save (PATCH, C8) echoes the observed
			    plan version; the committed changed-region patch is folded in by
			    `handleSaved` (scoped regions only, no full reload). */}
			<AssumptionEditor
				editor={editor}
				planVersion={workspace.planVersion}
				onSaved={handleSaved}
			/>
		</>
	);
}
