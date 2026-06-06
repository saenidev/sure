// Forecast V2 ForecastPlanShell (slice C3).
//
// The top-level workspace frame (spec "Forecast Component Contracts" ->
// `ForecastPlanShell`: "top-level workspace frame, lens nav, scenario stack,
// freshness, and region keys for partial reloads"). It frames plan identity, the
// lens nav, the live scenario-stack summary, and the freshness badge, then yields
// stable, keyed regions (metric strip, chart, inspector, assumptions, issues)
// that later slices fill and that scoped prop reloads / JSON patches target
// without CSS-selector coupling.
//
// State ownership: the shell reads shared selection from `useForecastWorkspace`
// (the only shared store) and renders chrome + slots. It never owns canonical
// plan truth, never fetches, and never recomputes. Lens nav is keyboard-reachable
// (a real <nav> of <button>s with aria-current); the active lens lives in the
// shared store.
//
// Tokens only — no raw palette. The freshness presentation is delegated to
// `FreshnessIndicator`.

import type { JSX, ReactNode } from "react";
import {
	FORECAST_REGIONS,
	type ForecastWorkspaceStore,
} from "../hooks/useForecastWorkspace";
import { ft } from "../i18n";
import type { PlanReadModel } from "../types/readModels";
import FreshnessIndicator from "./FreshnessIndicator";

// Inline SVG glyph (an upward trend line) using currentColor — no raw palette,
// no lucide_icon dependency. The token text color drives the stroke.
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
			className="size-5 text-secondary"
		>
			<path d="M3 17l6-6 4 4 8-8" />
			<path d="M17 7h4v4" />
		</svg>
	);
}

// One scenario-stack chip. Renders the localized "Baseline" label for the
// baseline layer and the raw layer key otherwise (real per-layer labels arrive
// with the scenario lens).
function ScenarioStackSummary({
	layers,
}: {
	readonly layers: readonly string[];
}): JSX.Element {
	const visible = layers.length > 0 ? layers : ["baseline"];
	return (
		<div className="flex flex-wrap items-center gap-1.5">
			<span className="text-xs text-subdued">
				{ft("forecasts.workspace.scenario_stack")}
			</span>
			{visible.map((layer) => (
				<span
					key={layer}
					className="rounded-md border border-primary bg-surface-inset px-2 py-0.5 text-xs font-medium text-secondary"
				>
					{layer === "baseline" ? ft("forecasts.workspace.baseline") : layer}
				</span>
			))}
		</div>
	);
}

// Keyboard-reachable lens nav. Each lens is a real <button> so it is focusable
// and operable by keyboard; the active lens is announced with aria-current.
function LensNav({
	lenses,
	activeLens,
	onSelect,
}: {
	readonly lenses: readonly string[];
	readonly activeLens: string;
	readonly onSelect: (lens: string) => void;
}): JSX.Element {
	return (
		<nav
			aria-label={ft("forecasts.workspace.title")}
			className="flex flex-wrap items-center gap-1 rounded-lg border border-primary bg-surface-inset p-1"
		>
			{lenses.map((lens) => {
				const isActive = lens === activeLens;
				return (
					<button
						key={lens}
						type="button"
						data-testid={`forecast-lens-${lens}`}
						aria-current={isActive ? "page" : undefined}
						onClick={() => onSelect(lens)}
						className={`rounded-md px-3 py-1 text-sm font-medium capitalize transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400 ${
							isActive
								? "bg-container text-primary shadow-sm"
								: "text-secondary hover:text-primary"
						}`}
					>
						{lens}
					</button>
				);
			})}
		</nav>
	);
}

export interface ForecastPlanShellProps {
	readonly plan: PlanReadModel;
	readonly workspace: ForecastWorkspaceStore;
	/** The keyed workspace regions the shell frames (strip, chart, inspector, …). */
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
			className="mx-auto flex h-full w-full max-w-7xl flex-col gap-6 p-4 sm:p-6"
		>
			<header className="flex flex-wrap items-start justify-between gap-4">
				<div className="flex items-center gap-3">
					<span className="flex size-10 items-center justify-center rounded-lg border border-primary bg-surface-inset">
						<PlanGlyph />
					</span>
					<div className="flex flex-col gap-1">
						<h1
							data-testid="forecast-plan-name"
							className="text-xl font-semibold text-primary"
						>
							{plan.name}
						</h1>
						<div className="flex flex-wrap items-center gap-x-3 gap-y-1">
							<p className="text-sm text-secondary">
								{plan.reporting_currency} ·{" "}
								{ft("forecasts.workspace.plan_version", {
									version: workspace.planVersion,
								})}
							</p>
							<ScenarioStackSummary
								layers={workspace.scenarioStackKey.split("+")}
							/>
						</div>
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

			<LensNav
				lenses={plan.lenses}
				activeLens={workspace.activeLens}
				onSelect={workspace.setLens}
			/>

			{children}
		</div>
	);
}
