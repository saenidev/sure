// Forecast V2 ForecastSidebar — ProjectionLab-style dark "Plans" rail
// (Phase 1 redesign).
//
// The dark left rail from ProjectionLab's "Current Projections" dashboard: a
// brand/plan header, a "Plans" group with the active Current Projections item and
// a New scenario action, the live scenario-stack as a "Scenarios" list, and a
// footer (version / help / support). It is presentational only — it reads plan
// identity + the shared scenario stack and renders chrome; it owns no plan truth
// and issues no requests. (New scenario / footer actions are wired in later
// slices; for Phase 1 they render as affordances.)
//
// Dark palette is forecast-scoped raw hex, kept inside this route's tree so the
// global Sure design system is untouched.

import type { JSX } from "react";
import type { ForecastWorkspaceStore } from "../hooks/useForecastWorkspace";
import { ft } from "../i18n";
import type { PlanReadModel } from "../types/readModels";

function ChartGlyph(): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="size-4"
    >
      <path d="M3 3v18h18" />
      <path d="M7 14l4-4 3 3 5-6" />
    </svg>
  );
}

function PlusGlyph(): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="size-4"
    >
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function LayersGlyph(): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="size-4"
    >
      <path d="M12 2 2 7l10 5 10-5-10-5Z" />
      <path d="m2 17 10 5 10-5M2 12l10 5 10-5" />
    </svg>
  );
}

export interface ForecastSidebarProps {
  readonly plan: PlanReadModel;
  readonly workspace: ForecastWorkspaceStore;
}

export default function ForecastSidebar({
  plan,
  workspace,
}: ForecastSidebarProps): JSX.Element {
  const layers = workspace.scenarioStackKey
    .split("+")
    .filter((layer) => layer.length > 0);
  const scenarioLayers = layers.length > 0 ? layers : ["baseline"];

  return (
    <aside
      data-testid="forecast-sidebar"
      aria-label={ft("forecasts.sidebar.plans")}
      className="hidden h-full w-64 shrink-0 flex-col bg-[#1B1F2A] text-[#E2E8F0] lg:flex"
    >
      {/* Brand / plan header. */}
      <div className="flex items-center gap-3 border-b border-white/5 px-5 py-5">
        <span className="flex size-9 items-center justify-center rounded-lg bg-gradient-to-br from-[#818CF8] to-[#2DD4BF] text-white">
          <ChartGlyph />
        </span>
        <div className="flex min-w-0 flex-col">
          <span className="truncate text-sm font-semibold text-white">
            {plan.name}
          </span>
          <span className="text-xs text-[#94A3B8]">
            {plan.reporting_currency}
          </span>
        </div>
      </div>

      {/* Plans group. */}
      <nav className="flex flex-1 flex-col gap-6 overflow-y-auto px-3 py-5">
        <div className="flex flex-col gap-1">
          <p className="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-[#64748B]">
            {ft("forecasts.sidebar.plans")}
          </p>
          <span
            aria-current="page"
            className="flex items-center gap-2.5 rounded-lg bg-white/10 px-3 py-2 text-sm font-medium text-white"
          >
            <ChartGlyph />
            {ft("forecasts.sidebar.current_projections")}
          </span>
          <button
            type="button"
            data-testid="forecast-sidebar-new-scenario"
            className="flex items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm text-[#94A3B8] transition-colors hover:bg-white/5 hover:text-white"
          >
            <PlusGlyph />
            {ft("forecasts.sidebar.new_scenario")}
          </button>
        </div>

        {/* Scenario stack. */}
        <div className="flex flex-col gap-1">
          <p className="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-[#64748B]">
            {ft("forecasts.sidebar.scenarios")}
          </p>
          {scenarioLayers.map((layer) => (
            <span
              key={layer}
              className="flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm text-[#CBD5E1]"
            >
              <LayersGlyph />
              <span className="truncate capitalize">
                {layer === "baseline"
                  ? ft("forecasts.sidebar.baseline")
                  : layer}
              </span>
            </span>
          ))}
        </div>
      </nav>

      {/* Footer. */}
      <div className="flex flex-col gap-1 border-t border-white/5 px-3 py-4 text-sm text-[#94A3B8]">
        <span className="px-3 py-1.5 text-xs">
          {ft("forecasts.sidebar.version", { version: workspace.planVersion })}
        </span>
        <a
          href="https://github.com/we-promise/sure"
          target="_blank"
          rel="noreferrer"
          className="rounded-lg px-3 py-1.5 transition-colors hover:bg-white/5 hover:text-white"
        >
          {ft("forecasts.sidebar.help")}
        </a>
      </div>
    </aside>
  );
}
