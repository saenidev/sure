// Forecast V2 ForecastPlanShell — ProjectionLab-style workspace frame
// (Phase 1 redesign).
//
// The top-level workspace frame, restructured to ProjectionLab's "Current
// Projections" dashboard shape: a dark left "Plans" rail (`ForecastSidebar`), a
// light airy content column with a slim top bar (plan identity + freshness), and
// the yielded workspace body (chart, breakdown, assumptions, issues). It still
// frames plan identity + freshness and exposes the stable shell region keys that
// scoped prop reloads / JSON patches target without CSS-selector coupling.
//
// State ownership: the shell reads shared selection from `useForecastWorkspace`
// and renders chrome + slots; it never owns plan truth, never fetches, never
// recomputes. The shell region carries the plan id / version / scenario-stack
// data attributes the proof-slice test reads. Freshness presentation is
// delegated to `FreshnessIndicator`.
//
// Colors are forecast-scoped raw hex (the faithful ProjectionLab light palette
// the user chose), kept inside this route's tree so the global Sure design
// system stays untouched.

import type { JSX, ReactNode } from "react";
import {
  FORECAST_REGIONS,
  type ForecastWorkspaceStore,
} from "../hooks/useForecastWorkspace";
import { ft } from "../i18n";
import type { PlanReadModel } from "../types/readModels";
import ForecastSidebar from "./ForecastSidebar";
import FreshnessIndicator from "./FreshnessIndicator";

// Inline brand glyph (upward trend) shown next to the plan name on small screens
// where the dark sidebar (which carries the brand) is hidden.
function PlanGlyph(): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="size-4 text-white"
    >
      <path d="M3 3v18h18" />
      <path d="M7 14l4-4 3 3 5-6" />
    </svg>
  );
}

export interface ForecastPlanShellProps {
  readonly plan: PlanReadModel;
  readonly workspace: ForecastWorkspaceStore;
  /** The keyed workspace regions the shell frames (chart, breakdown, …). */
  readonly children: ReactNode;
}

export default function ForecastPlanShell({
  plan,
  workspace,
  children,
}: ForecastPlanShellProps): JSX.Element {
  return (
    <div
      data-testid={FORECAST_REGIONS.shell}
      data-region={FORECAST_REGIONS.shell}
      data-plan-id={plan.id}
      data-plan-version={workspace.planVersion}
      data-scenario-stack-key={workspace.scenarioStackKey}
      className="flex h-full w-full bg-[#F6F7F9]"
    >
      <ForecastSidebar plan={plan} workspace={workspace} />

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-[#E3E8EF] bg-white/85 px-6 py-3.5 backdrop-blur">
          <div className="flex items-center gap-3">
            <span className="flex size-9 items-center justify-center rounded-lg bg-gradient-to-br from-[#818CF8] to-[#2DD4BF] lg:hidden">
              <PlanGlyph />
            </span>
            <div className="flex flex-col">
              <h1
                data-testid="forecast-plan-name"
                className="text-lg font-semibold text-[#0F172A]"
              >
                {plan.name}
              </h1>
              <p className="text-xs text-[#94A3B8]">
                {plan.reporting_currency} ·{" "}
                {ft("forecasts.workspace.plan_version", {
                  version: workspace.planVersion,
                })}
              </p>
            </div>
          </div>

          <div
            data-region={FORECAST_REGIONS.freshness}
            className="flex items-center"
          >
            <FreshnessIndicator
              freshness={workspace.freshness}
              regionKey={FORECAST_REGIONS.freshness}
            />
          </div>
        </header>

        <main className="flex-1 overflow-y-auto px-4 py-5 sm:px-6 sm:py-6">
          {children}
        </main>
      </div>
    </div>
  );
}
