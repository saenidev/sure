// Forecast V2 workspace Inertia page (slice C3; Phase 1 ProjectionLab redesign).
//
// The top-level V2 React page rendered by `ForecastsController#show` (V2 path)
// and `#v2` through the dedicated `forecast_inertia` layout. It receives the
// typed first-viewport props assembled by
// `Forecasts::WorkspaceLoading#forecast_v2_workspace_props` (one region per read
// model) and wires them into the workspace frame.
//
// State ownership (spec "State Ownership", "Frontend Runtime Modules"): this page
// stands up the ONE shared store (`useForecastWorkspace`) seeded from the props,
// then hands the shell + components their slices. The server owns canonical plan
// truth; this page owns only ephemeral interaction state. There are NO network
// requests on first paint — every region renders from preloaded props.
//
// Phase 1 redesign: the body is laid out as ProjectionLab's "Current Projections"
// dashboard — a dark Plans sidebar (in `ForecastPlanShell`), a center column with
// the KPI strip, the stacked gradient bar chart, and the assumptions/issues, and
// a right-hand breakdown panel for the selected period.

import { Head } from "@inertiajs/react";
import { type JSX, useCallback, useState } from "react";
import AssumptionEditor from "../../forecast/components/AssumptionEditor";
import AssumptionGroup from "../../forecast/components/AssumptionGroup";
import BreakdownPanel from "../../forecast/components/BreakdownPanel";
import ForecastPlanShell from "../../forecast/components/ForecastPlanShell";
import IssuePanel from "../../forecast/components/IssuePanel";
import MetricStrip, {
  metricsToStripEntries,
} from "../../forecast/components/MetricStrip";
import ProjectionChart from "../../forecast/components/ProjectionChart";
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
        <p className="rounded-2xl border border-[#E3E8EF] bg-white p-6 text-sm text-[#64748B]">
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

  // The typed editor drawer (slice C7): opens from an assumption card and composes
  // the salary form. It owns NONE of plan/period/scenario state, so opening/closing
  // preserves the selected period + scenario stack.
  const editor = useAssumptionEditor();

  // Fold a committed save's typed changed-region patch (slice C8) into the
  // workspace WITHOUT a full reload: the shared store takes the new plan version +
  // scenario stack + freshness, which recompute the scoped region cache keys, and
  // the saved card replaces its prior version in the rail.
  const handleSaved = useCallback(
    (patch: SavedAssumptionPatch): void => {
      workspace.applyAssumptionPatch(patch);
      setAssumptionGroups((groups) => applySavedCard(groups, patch));
    },
    [workspace],
  );

  // The single editor-open path shared by the assumption rail AND the breakdown
  // panel. Opening the typed editor drawer IN PLACE preserves the selected period
  // + scenario stack (the editor owns none of that state).
  const openAssumptionEditor = useCallback(
    (assumptionId: string, invokerId: string): void => {
      editor.open({ assumptionId, invokerId });
    },
    [editor],
  );

  // Serve the selected-period detail from the preloaded seed + local cache,
  // fetching GET /forecast/periods/:period_key only on a settled cache miss
  // (debounced). The workspace store reports SETTLED selections only, so chart
  // hover/scrub never reaches the network.
  const period = usePeriodPayloadCache({
    selectedPeriodKey: workspace.selectedPeriodKey,
    seed: selectedPeriod,
    cacheKey: cacheKeys.inspector,
  });

  // The aligned KPI strip tracks the served period (so it updates on selection),
  // falling back to the seed for the first paint.
  const metricsSource = period.payload ?? selectedPeriod;
  const metricEntries = metricsSource
    ? metricsToStripEntries(metricsSource.metrics)
    : [];

  return (
    <>
      <Head title={`${plan.name} · ${ft("forecasts.workspace.title")}`} />

      <ForecastPlanShell plan={plan} workspace={workspace}>
        <div className="flex flex-col gap-6 lg:flex-row lg:items-start">
          {/* Center column: KPI strip, the stacked gradient bar chart, then the
              assumptions + issues. */}
          <div className="flex min-w-0 flex-1 flex-col gap-6">
            <MetricStrip
              entries={metricEntries}
              regionKey={FORECAST_REGIONS.metricStrip}
            />

            {/* Stacked gradient bar chart (Phase 1): cash + investments above
                zero, debt below, net-worth line riding the tops. Pointer/keyboard
                scrubbing is local-only and reports settled selections with zero
                network. */}
            <ProjectionChart
              band={band}
              selectedPeriodKey={workspace.selectedPeriodKey}
              onSelectPeriod={workspace.selectPeriod}
              selectedMetric={workspace.selectedMetric}
              onSelectMetric={workspace.selectMetric}
              currency={plan.reporting_currency}
              regionKey={FORECAST_REGIONS.chart}
              cacheKey={cacheKeys.chart}
            />

            <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
              <AssumptionRail
                assumptionGroups={assumptionGroups}
                regionKey={FORECAST_REGIONS.assumptions}
                cacheKey={cacheKeys.assumptions}
                onEditCard={(cardId) =>
                  openAssumptionEditor(
                    cardId,
                    `forecast-assumption-edit-${cardId}`,
                  )
                }
              />

              {/* Issue panel: recoverable plan/source issues with impact +
                  remediation actions, privacy-safe (no raw UUIDs). */}
              <IssuePanel
                issues={props.issues}
                regionKey={FORECAST_REGIONS.issues}
                cacheKey={cacheKeys.issues}
              />
            </div>
          </div>

          {/* Right column: the ProjectionLab-style breakdown panel for the
              selected period. Carries the `forecast-selected-period` region id so
              a committed save still patches exactly this region. */}
          <BreakdownPanel
            payload={period.payload}
            status={period.status}
            refresh={period.refresh}
            currency={plan.reporting_currency}
            regionKey={FORECAST_REGIONS.inspector}
            cacheKey={cacheKeys.inspector}
            onOpenAssumption={(assumptionId) =>
              openAssumptionEditor(
                assumptionId,
                `forecast-inspector-assumption-${assumptionId}`,
              )
            }
          />
        </div>
      </ForecastPlanShell>

      {/* Typed editor drawer (C7): the only interactive editor in the MVP is the
          salary form. It renders OVER the workspace, so opening/closing preserves
          the selected period + scenario stack. */}
      <AssumptionEditor
        editor={editor}
        planVersion={workspace.planVersion}
        onSaved={handleSaved}
      />
    </>
  );
}
