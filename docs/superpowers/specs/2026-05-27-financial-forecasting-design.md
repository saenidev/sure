# Financial Forecasting Design

Status: Ready for user review
Date: 2026-05-27

## Purpose

Build a full personal financial forecasting capability as an integrated module inside this Sure fork. The module should project household finances across a 0-36 month horizon, combining deterministic financial data from Sure with contextual scenario analysis from the Hermes agent.

The product is not a stock-market-only tool. Portfolio performance and market-close movements are inputs to a broader forecast that includes cashflow, budgets, one-time events, recurring transactions, debt, savings, investments, net worth, and recommendations.

## Agreed Direction

Use Sure as the auditable financial forecasting system and Hermes as the context-rich scenario analyst.

Sure owns:

- Deterministic baseline forecast calculations.
- Monthly budget forecast data and visualizations.
- Manual assumptions and simple manual scenarios.
- One-time income, one-time expenses, and other forecast events.
- Stored forecast runs for history and auditability.
- Market-close portfolio inputs from existing market data and holding models.
- Weekly review scheduling and persisted review outputs.

Hermes owns:

- Personal-life-context-aware scenario reasoning.
- Scenario interpretation and narrative review.
- Suggested scenarios and recommendations.
- Follow-up analysis through Sure chat or a forecast-specific Hermes interaction.

## Repository Context

Relevant existing Sure concepts:

- `Family`: household scope for accounts, budgets, categories, entries, transactions, trades, holdings, and recurring transactions.
- `Budget` and `BudgetCategory`: existing monthly budget route/UI and category budget source.
- `RecurringTransaction`: recurring income, spending, and transfer patterns, including manual recurring entries.
- `Entry` and `Transaction`: cashflow source data.
- `Account`, `BalanceSheet`, and `IncomeStatement`: account balances, net worth, income, and spending analytics.
- `InvestmentStatement`, `Holding`, `Security`, `Security::Price`, and `MarketDataImporter`: portfolio value, holdings, market-close prices, and daily market-data ingestion.
- `Assistant::External`: existing external streamed assistant integration that can connect Sure chat to Hermes-style agents.
- `McpController`: existing token-authenticated MCP endpoint exposing Sure assistant functions to external agents.

Current git context:

- `origin` points to `https://github.com/saenidev/sure.git`.
- `upstream` points to `https://github.com/we-promise/sure.git`.
- `we-promise-fork` points to `https://github.com/saenidev/sure-we-promise.git`.
- The current worktree already has unrelated modifications, so implementation must avoid reverting or trampling existing changes.

## Forecast Horizon

The forecast covers 0-36 months with different precision by distance:

- 0-90 days: daily cash runway, upcoming transactions, short-term risk detection.
- 3-12 months: monthly budget, recurring cashflow, debt, savings, portfolio-aware net worth.
- 12-36 months: lower-precision scenario projection with explicit assumptions.

## Upstream Dependency: Debt Account Interest Accrual

Sure currently supports untracked debt or liability accounts, but may not support automatic interest accrual for those accounts. Full debt forecasting should depend on an upstream debt-account feature that establishes existing debt behavior first.

Before debt forecasting is considered complete, Sure should support debt account assumptions such as:

- Principal balance.
- Interest rate.
- Accrual cadence.
- Minimum payment.
- Payment due date.
- Optional promotional or variable-rate periods.
- Optional manual interest adjustments.
- Account-level display of projected payoff behavior.

This should be treated as a related but separate prerequisite feature. The forecasting module can then consume established debt account mechanics instead of duplicating or inventing liability behavior inside forecast-only code.

## Forecasting Spine: Monthly Budget Scenarios

The monthly budget forecast is the central organizing model.

The feature should extend the existing budgets route and UI rather than creating a completely separate budgeting surface. Existing `Budget` and `BudgetCategory` records remain the current known-plan source. Forecast-specific future and hypothetical values should live in new forecast-owned records so actual budgets are not polluted by scenario data.

Each forecast month should support adjustable assumptions:

- Expected income.
- Category-level spending.
- Recurring transactions.
- One-time income.
- One-time expenses.
- Potential single or recurring forecast items that do not exist as transactions yet.
- Transfers.
- Savings contributions.
- Debt payments.
- Future one-time debt.
- Growing debt balances.
- Portfolio contributions or withdrawals.
- Market return assumptions.
- Other user-entered factors that affect cash, budget, portfolio, debt, or net worth.

Forecast-only items are required. Users need to model expected future events before they exist in Sure's transaction ledger: planned bonuses, rent changes, tax payments, medical bills, insurance renewals, travel, tuition, new subscriptions, expected reimbursements, future transfers, and similar items.

These planned items should stay separate from actual `Entry` and `Transaction` records until a real transaction exists. When the real transaction arrives, the user or a matching process should be able to link it back to the forecast item. This preserves auditability:

- Forecast items answer "what did I expect?"
- Transactions answer "what actually happened?"
- Linked items support variance analysis between expected and actual timing, amount, category, account, and merchant.

The forecast should support a distribution of possible monthly outcomes, not only a single baseline line. Scenario outputs should be pivotable by:

- Month.
- Scenario.
- Category.
- Cash runway.
- Budget performance.
- Net worth.
- Portfolio value.
- Debt balance.
- Deterministic scenario band or confidence classification.

The whole forecasting system should follow a timeline axis. The timeline is the primary interaction model for understanding what changes when. Users should be able to see baseline forecast months, planned forecast events, scenario layers, Hermes-suggested items, and actual linked transactions on the same chronological surface.

All primary forecasting timelines should be available on the same page. The UI can use lanes, filters, collapsible sections, or synchronized panels, but users should not have to navigate to a separate product area to understand how budget, cash, portfolio, debt, and life-event scenarios interact.

Scenarios should behave like toggleable layers:

- A scenario can be enabled or disabled without deleting it.
- Multiple scenarios can stack together to show combined effects.
- Scenario layers should be rearrangeable chronologically when their events move.
- Scenario effects should remain traceable to their source layer.
- Turning off a scenario should remove only that scenario's effects from the displayed forecast.
- A combined forecast should show which active scenarios are contributing to each projected month.

Chronological rearrangement matters for both planning and interpretation. A job change starting in July should produce a different projection than the same job change starting in October. A one-time expense before a bonus may create cash-runway risk that disappears if the order is reversed.

The stock market and portfolio forecast should have its own synchronized timeline lane on the same page. It should show market-close price movements, holding changes, portfolio performance, contributions, withdrawals, market-triggered scenario suggestions, and portfolio assumptions. It remains connected to the master forecast timeline through portfolio value, investment cashflows, taxes, liquidity needs, and net worth effects.

Debt should also be a first-class synchronized timeline lane. The forecast must model existing debt, future one-time debt, debt drawdowns, growing balances, interest accrual, minimum payments, planned extra payments, refinancing assumptions, payoff timing, and debt-to-cash/net-worth effects. Debt events should be visible beside budget, cash, life-event, and portfolio timelines because timing determines liquidity risk.

Debt forecasting should reuse Sure's core debt-account interest accrual once that exists. Forecast-only debt projections can still model hypothetical future debt and scenario-specific extra payments, but established real debt should come from account-level debt mechanics.

## Required Foundations

The system must include these foundations. They are not optional polish; they are what make the forecasting system auditable and useful at any scale.

### Assumption Versioning

Every forecast run must preserve the exact assumptions used to generate it. Weekly reviews, Hermes analysis, and scenario comparisons are only meaningful if old runs remain explainable after the user changes income, rent, goals, scenario dates, market assumptions, or forecast events.

Forecast runs should snapshot:

- Active scenario IDs and effective dates.
- Forecast settings and horizon.
- Budget projection inputs.
- Forecast events active at run time.
- Goal targets.
- Liquidity classification settings.
- Debt assumptions.
- Portfolio and market assumptions.
- Hermes packet schema version and response version, when applicable.

The current editable assumptions may continue changing, but historical `ForecastRun` records should remain tied to the assumptions used at generation time. If the forecast packet changes schema, the version should be stored so older Hermes reviews can still be interpreted.

### Forecast Item Reconciliation

Forecast-only items need a lifecycle. The system should not simply display future assumptions and forget them after the date passes.

Minimum lifecycle states:

- `planned`: forecast item is expected in the future.
- `due_soon`: item is near its expected date and should be watched.
- `matched`: one or more real entries or transactions have been linked.
- `missed`: expected date passed and no matching transaction was found.
- `variance_reviewed`: user reviewed the difference between expected and actual.
- `canceled`: user explicitly decided the forecast item will not happen.

Matching should support both manual and automated flows. Automated matching can start simple: compare date window, amount tolerance, account, category, merchant/name, and direction. Manual linking must always be available because financial data often has ambiguous timing and naming.

Variance analysis should track:

- Expected date vs actual date.
- Expected amount vs actual amount.
- Expected category vs actual category.
- Expected account vs actual account.
- Expected merchant/name vs actual merchant/name.
- Partial matches when one planned item resolves into multiple actual transactions.

This reconciliation loop is how the forecast learns whether assumptions were reliable.

### Liquidity-Aware Forecasting

The forecast must distinguish cash runway from net worth. A user can have positive net worth and still run out of liquid cash.

At minimum, accounts and projected values should be grouped into liquidity classes:

- `cash`: checking, savings, cash-like balances available for spending.
- `credit_available`: available credit or debt capacity, shown separately from cash.
- `liquid_investment`: taxable brokerage or crypto assets that could be sold, but may have market/tax risk.
- `restricted_or_long_term`: retirement, locked, illiquid, or otherwise not intended for cash runway.
- `physical_or_illiquid_asset`: property, vehicles, or other assets that affect net worth but not short-term liquidity.
- `debt`: liabilities and projected debt balances.

The implementation can infer sensible defaults from existing account classification/accountable types, but users must be able to override liquidity treatment per account or per scenario.

Forecast outputs should show at least:

- Cash runway.
- Cash plus liquid runway.
- Net worth.
- Debt balance.
- Available credit separately from cash.

Recommendations should not treat liquid cash, long-term investments, and available credit as equivalent.

### Hermes Approval Boundary

Hermes can suggest scenarios, explain risks, and recommend actions, but Hermes should not silently activate scenario layers or mutate baseline forecast assumptions.

Hermes-generated output should enter Sure as drafts:

- Draft scenario.
- Draft forecast event.
- Draft recommendation.
- Draft review note.
- Draft follow-up question.

The user must approve, edit, reject, or archive suggested scenario effects before they alter the active combined forecast. Sure may display a preview of Hermes suggestions, but the deterministic active forecast should remain controlled by Sure data plus user-approved assumptions.

This boundary protects the audit trail and keeps the product from becoming an opaque agent-controlled ledger.

### Basic Goals

The forecast needs goals so recommendations have a target. Without goals, Hermes and deterministic rules can only say that things changed, not whether the change matters.

First-scope goals:

- Minimum cash buffer.
- Minimum cash runway duration.
- Scenario-specific runway requirement.
- Monthly savings target.
- Debt payoff target or desired payoff date.
- Portfolio contribution target.
- Optional life-event target, such as moving-country readiness or new-job transition runway.

Goals should be family-scoped and may be scenario-specific. A moving-country scenario may have different cash buffer, currency, and runway goals than the baseline.

Goal progress should be visible in forecast outputs:

- On track.
- At risk.
- Off track.
- Unknown because required assumptions are missing.

Hermes reviews should reference these goals explicitly when making recommendations.

Goals are not scenarios by default. A scenario changes projected financial reality; a goal defines how to evaluate whether that projected reality is acceptable. For example, "move to Korea in October" is a scenario, while "maintain 9 months of cash runway after moving" is a goal used to judge that scenario.

Goals can enable, disable, or gate potential scenarios through evaluation:

- A scenario can be marked feasible if all required goals remain on track.
- A scenario can be marked at risk if one or more goals fall below target.
- A scenario can be marked blocked if a hard goal fails, such as minimum runway or minimum cash buffer.
- A scenario can become active only after the user accepts the goal tradeoff or changes assumptions.

This keeps goals reusable across scenarios. The same runway goal can evaluate a job-loss scenario, a moving-country scenario, a market-drawdown scenario, and a new-debt scenario without duplicating goal logic.

### Simple Confidence

Forecast inputs and scenario effects should carry confidence. The foundation can start with simple labels, then expand into probability distributions once deterministic scenario modeling is trusted.

Minimum confidence values:

- `confirmed`: known or user-confirmed item, such as signed rent, fixed loan payment, or confirmed payroll.
- `likely`: expected but not guaranteed, such as recurring discretionary spending or anticipated reimbursement.
- `speculative`: possible scenario item, Hermes suggestion, or unconfirmed life event.

Confidence should influence display and review:

- Confirmed items render as firmer timeline items.
- Likely items render as normal assumptions.
- Speculative items render as softer scenario effects and should be easy to toggle off.
- Hermes should call out material speculative assumptions before making strong recommendations.

Confidence is separate from scenario type. A manual scenario can contain speculative items, and a Hermes-suggested scenario can contain confirmed user-provided facts after review.

## Compatibility Reconciliation

The current concepts are compatible, but only if the implementation separates editable planning objects from generated forecast outputs. The biggest design risk is treating scenarios, forecast months, distributions, and runs as the same thing. They should remain separate.

### Planning Objects vs Generated Outputs

Long-lived editable planning objects:

- `ForecastScenario`: a toggleable layer such as baseline, move-country, new job, market drawdown, or Hermes suggestion.
- `ForecastEvent`: a dated or recurring effect inside a scenario, such as income, expense, transfer, debt drawdown, or contribution.
- `ForecastGoal`: a target used to evaluate forecast outcomes.
- `ForecastAccountLiquiditySetting`: account-level liquidity classification and overrides.

Generated output objects:

- `ForecastRun`: immutable snapshot of inputs and generated results at a point in time.
- `ForecastMonth`: generated aggregate result for a month under a specific scenario stack.
- `ForecastCategoryProjection`: generated category-level budget projection for a forecast month.
- `ForecastDebtProjection`: generated debt projection for a forecast month.
- `ForecastReview`: Hermes and deterministic review output for a forecast run.

This separation keeps user-editable assumptions from corrupting historical forecast runs. Editing a scenario should create different future runs, not rewrite old runs.

### Scenario Stacking Semantics

Scenarios are toggleable layers. A combined forecast is produced by applying all active layers to the baseline over the forecast timeline.

Scenario display order and timeline position are not the same:

- Timeline position comes from event dates and recurrence rules.
- Display order controls UI organization when multiple layers are shown.
- Calculations should be driven by dates and effect types, not arbitrary UI order.

Most scenario effects should be additive: extra income, extra expense, savings contribution, debt drawdown, market return assumption, or transfer. Some effects are overrides: replacing salary amount, replacing rent, changing account liquidity, or changing a budget category assumption.

When overlapping effects conflict, explicit overrides should win over inherited baseline values, and user-approved manual overrides should win over Hermes drafts. The engine should record which layer supplied each effect so the UI can explain combined results.

### Distribution Representation

The foundation should represent distribution through scenario stacks plus confidence. More advanced probability modeling can build on top of that.

Initial distribution model:

- Baseline stack: currently active confirmed assumptions.
- Downside stack: baseline plus selected pessimistic/stress scenarios.
- Upside stack: baseline plus selected optimistic scenarios.
- Custom stack: any user-selected combination of scenario layers.

The UI can show these as bands or comparisons, but they are deterministic scenario bands, not statistical percentiles. Percentiles and Monte Carlo can be added later once the deterministic engine is trusted.

### Budget Projection Inheritance

Future monthly budget projections should start by inheriting from the most relevant existing budget data:

- Current initialized `Budget` and `BudgetCategory` values where available.
- Latest initialized budget as the default for future months.
- Existing `RecurringTransaction` rows for recurring income, spending, and transfers.
- Existing actuals for the current month.

Forecast-specific records should store overrides and generated projections, not mutate future actual budget records unless the user explicitly applies them. This avoids polluting Sure's real budget history with hypothetical forecast data.

### Timeline Resolution

The system should use mixed resolution:

- Daily resolution for 0-90 days.
- Monthly resolution from month 4 through month 36.

The UI should present a unified timeline page with synchronized lanes. Continuous zoom can be added after the core timeline model is reliable.

### Debt Forecasting Sequence

Debt forecasting is compatible with the broader spec only if it is phased:

1. Implement or confirm core debt account interest accrual in Sure.
2. Let forecast generation consume established debt account mechanics for existing real debt.
3. Use forecast-only events for hypothetical future debt, new drawdowns, and scenario-specific extra payments.

Until core debt accrual exists, debt projections should be limited to manual/hypothetical debt events and current balances. Full payoff and growing-balance projections should wait for the upstream debt-account feature.

### Hermes Write Boundary

Hermes should not write active scenario layers directly. Hermes output should be stored as draft suggestions or review content first.

Allowed Hermes outputs:

- Draft scenario suggestion.
- Draft forecast event suggestion.
- Draft recommendation.
- Draft follow-up question.
- Narrative review.

The user must approve or edit suggested effects before they become active scenario layers. This resolves the tension between "Hermes has the most context" and "Sure remains auditable."

## Target Build Strategy

The product should be built as a comprehensive forecasting workspace, not a narrow toy forecast. The best architecture is still sequenced because later capabilities depend on trustworthy foundations.

This sequence does not limit the product ambition. It prevents the most complex parts from being built on untestable assumptions.

### Phase 0: Branch, Feature Gate, and Design Contracts

Purpose: make the work safe to build inside the fork without destabilizing the rest of Sure.

Scope:

- Work on a dedicated forecasting branch.
- Add a preview/feature flag for the forecasting workspace.
- Finalize route placement and top-level navigation.
- Define enum values, lifecycle states, schema versions, and naming.
- Keep the written spec current as decisions become concrete.

Done when:

- Forecasting can be hidden behind a gate.
- The core model names, state machines, and route placement are no longer ambiguous.

### Phase 1: Debt Account Interest Accrual Prerequisite

Purpose: establish real debt behavior before relying on debt projections.

Scope:

- Add account-level debt assumptions for untracked liabilities.
- Support principal, interest rate, accrual cadence, minimum payment, due date, optional promotional/variable periods, and manual adjustments.
- Show projected payoff behavior at the account level.
- Keep this independent from forecast scenarios at first.

Done when:

- Existing untracked debt accounts can accrue interest predictably.
- Account-level debt projections are test-covered and can be consumed by forecasting.

Dependency note: full debt forecasting should wait for this. Other forecast foundations can be built before or alongside it, but debt-specific forecast outputs should not pretend to be complete until this phase exists.

### Phase 2: Core Forecast Planning Model

Purpose: create the editable planning layer.

Scope:

- `ForecastScenario`
- `ForecastEvent`
- `ForecastGoal`
- `ForecastAccountLiquiditySetting`
- Confidence, approval state, lifecycle state, source, recurrence, additive/override effect type, and scenario activation.
- Basic model validations and family scoping.

Done when:

- A user or seed/test can create scenarios, events, goals, and liquidity settings without generating a forecast run.
- Hermes-created drafts and manually-created objects can share the same shape.

### Phase 3: Deterministic Forecast Engine and Run Persistence

Purpose: generate reproducible forecast outputs from Sure data plus planning objects.

Scope:

- `Forecast::Engine`.
- `ForecastRun`.
- `ForecastMonth`.
- `ForecastCategoryProjection`.
- `ForecastDebtProjection` limited to current balances and hypothetical events until Phase 1 is connected.
- Goal evaluations.
- Source contribution metadata.
- Baseline, downside, upside, and custom scenario stack generation.

Done when:

- Running the engine creates immutable forecast outputs for 0-36 months.
- Daily cash rows exist for 0-90 days.
- Monthly projection rows exist through month 36.
- The same inputs generate the same outputs.
- Outputs can explain their sources.

### Phase 4: Manual Forecast Authoring UI

Purpose: make Sure usable without Hermes.

Scope:

- Scenario CRUD and toggle controls.
- Timeline event creation and editing.
- One-time and recurring planned items.
- Category budget projection overrides.
- Goal editing, including runway goals and hard/soft blocking behavior.
- Liquidity classification overrides.
- Scenario stack comparison controls.

Done when:

- A user can build a complete forecast manually through the UI.
- Hermes is optional, not required for the core workflow.

### Phase 5: Unified Timeline Workspace

Purpose: make forecasting visual and understandable on one page.

Scope:

- One forecast page with synchronized lanes for budget, cash, portfolio, debt, goals, life events, and scenario layers.
- Daily 0-90 day runway view.
- Monthly 4-36 month projection view.
- Scenario band comparison.
- Drilldowns for source contribution metadata.
- Same-page market/portfolio lane.

Done when:

- Users can see what happens when, which scenario caused it, and how it affects runway, budget, portfolio, debt, and goals without leaving the page.

### Phase 6: Forecast Item Reconciliation

Purpose: connect expected future items to actual financial data.

Scope:

- `ForecastEventLink`.
- Manual linking from forecast events to entries/transactions.
- Candidate matching by date, amount, account, category, merchant/name, and direction.
- Lifecycle transitions: planned, due soon, matched, missed, variance reviewed, canceled.
- Variance views.

Done when:

- A planned item can later be matched to one or more actual transactions.
- The UI can show expected-vs-actual variance.

### Phase 7: Full Debt Forecast Integration

Purpose: connect real debt mechanics to forecast outputs.

Scope:

- Consume Phase 1 debt account mechanics inside `Forecast::Engine`.
- Project interest accrual, minimum payments, planned extra payments, new drawdowns, payoff dates, and growing balances.
- Render debt timeline lane and debt goal evaluations.

Done when:

- Existing debt, future debt, and debt scenarios affect cash runway, net worth, and goals coherently.

### Phase 8: Hermes Forecast Packet and Approval Workflow

Purpose: add contextual reasoning without giving Hermes uncontrolled write access.

Scope:

- Forecast packet schema.
- Hermes response schema.
- Push forecast packets from Sure to Hermes.
- Store narrative review, draft scenario suggestions, draft forecast events, draft recommendations, and follow-up questions.
- Approval/edit/reject/archive workflow.
- Optional chat entry point connected to forecast context.

Done when:

- Hermes can review a forecast run and propose structured drafts.
- Nothing proposed by Hermes changes the active forecast until the user approves it.

### Phase 9: Weekly Review and Market-Close Triggers

Purpose: make forecasting a recurring review loop.

Scope:

- Weekly forecast run generation.
- Market-close portfolio movement summary.
- Material movement thresholds.
- Market-triggered scenario drafts.
- Review history.
- Superseded/failed/completed review states.

Done when:

- Sure can produce a weekly review after market-close data is available.
- Material portfolio or cashflow changes can trigger Hermes review drafts.

### Phase 10: Advanced Distribution and Optimization

Purpose: evolve from deterministic scenario bands toward richer forecasting.

Scope:

- Probability-aware bands.
- Better confidence scoring.
- Sensitivity analysis.
- Goal optimization and tradeoff exploration.
- Scenario templates for country move, job change, income loss, major debt, major purchase, portfolio drawdown, liquidity stress, and tax placeholders.

Done when:

- The system can answer not only "what happens under this scenario?" but "which changes best preserve my goals?"

## Work Package Breakdown

The phases above should become small, reviewable work packages. Each package should leave the app in a coherent state and should avoid half-wired UI that writes data the engine cannot interpret.

### 0A: Forecasting Feature Gate

- Add a preview flag for forecasting.
- Hide routes/navigation when disabled.
- Add a small route placeholder when enabled.
- Document the gate in the project preview-feature guide if needed.

### 0B: Route and Navigation Placement

- Decide final route structure.
- Use a dedicated `/forecast` workspace for the whole 0-36 month forecast.
- Add budget-context entry points from existing `budgets#show` and `budget_categories#index`.
- Avoid forcing the entire experience under a single budget month, because the forecast is 0-36 months and crosses months/scenarios.

### 1A: Debt Assumption Model

- Add account-level debt assumptions for liability accounts.
- Store interest rate, accrual cadence, minimum payment, due date, and effective periods.
- Keep debt assumptions editable outside forecasting.

### 1B: Debt Accrual Service

- Build a deterministic service that projects debt balance over time.
- Cover fixed-rate debt first.
- Add test fixtures for growing balances, minimum payments, extra payments, and payoff dates.

### 1C: Debt Account UI

- Add controls to untracked debt/liability account pages.
- Show projected payoff behavior.
- Keep this scoped to account-level debt behavior, not scenario forecasting.

### 2A: Forecast Planning Migrations

- Add tables for scenarios, events, goals, liquidity settings, and draft/approval metadata.
- Define enums and lifecycle states.
- Add indexes around family, scenario, status, date, and active state.

### 2B: Forecast Planning Models

- Add validations, scopes, family scoping, and lifecycle helpers.
- Add recurrence support for forecast events.
- Add confidence and source semantics.

### 2C: Forecast Planning Fixtures and Unit Tests

- Cover additive vs override effects.
- Cover scenario activation.
- Cover goal blocker behavior.
- Cover liquidity override behavior.
- Cover Hermes draft vs approved objects.

### 3A: Forecast Engine Input Builder

- Build a service that gathers budgets, categories, recurring transactions, accounts, holdings, goals, liquidity settings, and active scenario layers.
- Keep the input payload serializable for snapshots and tests.

### 3B: Forecast Engine Core

- Generate daily rows for 0-90 days.
- Generate monthly rows through month 36.
- Apply additive and override effects.
- Compute cash runway, cash plus liquid runway, net worth, category projections, portfolio values, debt summaries, goal evaluations, and risk flags.

### 3C: Forecast Run Persistence

- Persist immutable forecast runs and generated rows.
- Store input snapshots, schema versions, scenario-stack snapshots, and source contribution metadata.
- Add cleanup or retention rules if forecast runs become large.

### 3D: Engine Explainability Tests

- For each projected amount, verify source contribution metadata is present.
- Test deterministic repeatability.
- Test scenario toggling removes only that scenario's effects.
- Test conflicting override behavior.

### 4A: Manual Scenario Management UI

- Create/edit/archive/delete scenarios.
- Toggle active state.
- Duplicate scenarios.
- Show approval and confidence states.

### 4B: Manual Timeline Event UI

- Add one-time and recurring forecast events.
- Support income, expense, transfer, savings, portfolio flow, debt drawdown, debt payment, and tax placeholder effects.
- Support moving events chronologically.

### 4C: Manual Goals and Liquidity UI

- Add runway, cash buffer, savings, debt payoff, portfolio contribution, and life-event readiness goals.
- Mark goals as hard blockers or soft targets.
- Classify account liquidity and scenario-specific overrides.

### 4D: Budget Projection Editing

- Let users adjust projected category budgets by month.
- Show inherited budget values vs forecast overrides.
- Keep actual `Budget` records unchanged unless the user explicitly applies a forecast to a real budget.

### 5A: Timeline Read Model

- Build a read model for the unified page.
- Include lanes for budget, cash, portfolio, debt, goals, life events, scenario layers, and reviews.
- Keep this separate from write models so the UI can evolve without corrupting forecast math.

### 5B: Timeline Workspace UI

- Render daily 0-90 day runway and monthly 4-36 month projections on one page.
- Add scenario stack controls.
- Add same-page portfolio/market lane.
- Add drilldowns for source contribution metadata.

### 5C: Visualization Polish and Accessibility

- Add charts with design-system tokens.
- Ensure mobile and desktop layouts remain usable.
- Avoid raw palette colors and ad hoc UI primitives.

### 6A: Forecast Event Matching

- Generate match candidates from entries/transactions.
- Compare date window, amount tolerance, account, category, merchant/name, and direction.
- Present candidates in the UI.

### 6B: Manual Linking and Variance Review

- Link forecast events to one or more actual entries/transactions.
- Mark missed, canceled, matched, and variance-reviewed states.
- Show expected-vs-actual variance.

### 7A: Debt Engine Connection

- Connect account-level debt accrual to forecast engine inputs.
- Merge real debt projections with scenario debt events.
- Preserve explainability for debt numbers.

### 7B: Debt Timeline and Goal Evaluation

- Render debt lane.
- Evaluate payoff goals, growing balance risk, and debt-driven runway pressure.

### 8A: Hermes Packet Schema

- Define structured request JSON.
- Include forecast run, scenario stacks, goals, risk flags, liquidity summaries, portfolio summary, debt summary, forecast events, and questions for Hermes.
- Version the schema.

### 8B: Hermes Response Schema

- Define structured response JSON.
- Support narrative review, risks, recommendations, draft scenarios, draft events, follow-up questions, and confidence.
- Validate responses before storing.

### 8C: Hermes Approval UI

- Show draft suggestions.
- Let user approve, edit, reject, or archive suggestions.
- Convert approved drafts into normal editable forecast objects.

### 9A: Weekly Review Scheduler

- Generate weekly forecast runs.
- Trigger after market-close data is available.
- Store review lifecycle states.

### 9B: Material Movement Detection

- Detect material cashflow, budget, debt, portfolio, holding, or market changes.
- Generate deterministic risk flags.
- Decide whether a Hermes review is warranted.

### 9C: Review History

- Show past forecast runs and reviews.
- Compare current forecast to previous run.
- Explain what changed.

### 10A: Probability-Aware Bands

- Extend deterministic scenario bands with probability-aware modeling.
- Keep deterministic baseline/downside/upside stacks available.

### 10B: Scenario Templates and Optimizers

- Add templates for country move, job change, income loss, major debt, major purchase, market drawdown, liquidity stress, and tax placeholders.
- Add goal tradeoff exploration and suggestions.

## Dependency Map

Hard dependencies:

- Phase 3 depends on Phase 2 because the engine needs planning objects.
- Phase 4 depends on Phase 2 because the UI writes planning objects.
- Phase 5 depends on Phase 3 because the timeline needs generated forecast outputs.
- Phase 6 depends on Phase 2 and benefits from Phase 5 because reconciliation links forecast events to actuals.
- Phase 7 depends on Phase 1 and Phase 3 because real debt forecasting needs debt mechanics plus engine outputs.
- Phase 8 depends on Phase 3 because Hermes should review real forecast runs, not loose planning drafts.
- Phase 9 depends on Phase 3 and Phase 8 because weekly reviews need forecast runs and Hermes packets.
- Phase 10 depends on Phase 3 and Phase 5 because optimization needs trusted engine outputs and visible scenario comparison.

Parallelizable work:

- Phase 1 debt-account accrual can run alongside Phase 2 planning models.
- Phase 4 manual UI can start after Phase 2 before the final timeline workspace is complete.
- Phase 6 reconciliation can start with manual linking before automated matching is sophisticated.
- Phase 8 Hermes schema design can begin while Phase 3 is being built, but production Hermes reviews should wait for persisted forecast runs.
- Phase 9 market movement threshold design can begin while Phase 8 is in progress.

Do not shortcut:

- Do not let Hermes mutate active scenarios directly.
- Do not store hypothetical future assumptions in real `Budget`, `Entry`, or `Transaction` records.
- Do not build full debt forecasting before account-level debt accrual exists.
- Do not build probability-aware bands before deterministic scenario stacks are explainable.
- Do not make the timeline UI the source of forecast truth; it should read from planning objects and generated outputs.

## Forecast Engine Contract

The forecast engine should be a deterministic service with explicit inputs and outputs. Target service shape:

```ruby
Forecast::Engine.call(
  family:,
  user:,
  start_date:,
  horizon_months: 36,
  scenario_stack:,
  run_context:
)
```

Inputs:

- Family and user scope.
- Start date and horizon.
- Scenario stack definition.
- Budget inheritance inputs.
- Active forecast events.
- Goals.
- Liquidity settings.
- Recurring transactions.
- Account balances and classifications.
- Portfolio holdings and market data.
- Debt account mechanics and hypothetical debt events.
- Exchange-rate assumptions where relevant.

Outputs:

- Daily cash runway rows for the first 90 days.
- Monthly forecast rows through month 36.
- Category-level budget projections.
- Debt projections.
- Portfolio projections.
- Goal evaluations.
- Liquidity summaries.
- Deterministic risk flags.
- Source contribution metadata for explainability.

The engine should be pure enough to test with fixtures. Persistence should be handled by a runner that turns engine output into `ForecastRun` and related generated records.

## Scenario Effect Catalog

Scenario effects need concrete types so stacking and conflict resolution stay predictable.

First-class effect types:

- `income_add`: add income for a date or recurrence.
- `income_override`: replace inherited income assumptions for a period.
- `expense_add`: add expense for a date or recurrence.
- `expense_override`: replace inherited spending or category budget assumptions.
- `transfer_add`: add transfer between accounts or liquidity classes.
- `savings_contribution`: add planned savings.
- `portfolio_contribution`: add investment contribution.
- `portfolio_withdrawal`: add investment withdrawal.
- `market_return_override`: replace market return assumption for a holding, portfolio, or period.
- `debt_drawdown`: add new principal.
- `debt_payment`: add planned debt payment.
- `debt_terms_override`: change debt rate, minimum payment, due date, or accrual assumptions for a scenario.
- `liquidity_override`: change how an account is treated for runway.
- `goal_override`: change a goal target within a scenario.
- `currency_assumption`: set FX or currency behavior for a scenario period.
- `tax_placeholder`: add manual tax estimate or withholding adjustment.

Each effect should record source, confidence, approval state, effective date range, recurrence, and source-layer contribution metadata.

## Explainability Requirements

Every major projected number should be answerable with "why is this number here?"

For forecast outputs, store or derive:

- Source budget or inherited default.
- Source recurring transaction.
- Source forecast event.
- Source scenario layer.
- Source debt account mechanic.
- Source portfolio/market data.
- Source manual override.
- Source Hermes draft, once approved.

The UI should make this visible through drilldowns rather than requiring users to inspect raw JSON.

## Acceptance Criteria

The finished target system should support these workflows:

- User creates a future one-time expense on the timeline, sees cash runway and monthly budget projections update, and later links the actual transaction to review variance.
- User creates a recurring planned income change, applies it to a new-job scenario, and compares baseline vs new-job runway.
- User creates a moving-country scenario with currency, housing, income, tax placeholder, and runway goals, then sees whether the scenario is feasible or blocked.
- User toggles a market-drawdown scenario and sees portfolio, net worth, and goal impact without changing actual holdings.
- User models future debt, sees cash/net-worth/debt effects, and later connects real debt mechanics once account-level interest accrual exists.
- Hermes proposes a scenario after a weekly review; the scenario remains a draft until the user approves or edits it.
- User disables a scenario layer and sees only that scenario's effects removed from the combined forecast.
- User can inspect a projected monthly amount and see which budget, transaction pattern, event, scenario, or market input contributed to it.

## Scenario Types

Initial scenario families:

- Baseline: deterministic projection from current balances, budgets, recurring transactions, and known assumptions.
- Manual: user-created assumptions and one-time events for simpler calculations.
- Hermes-suggested: scenarios proposed by Hermes based on forecast packets and personal context.
- Market-close triggered: scenarios suggested after material portfolio or market movement.
- Life-event: major contextual changes such as moving to a new country, getting a new job, losing income, changing housing, starting school, visa changes, family changes, healthcare changes, or changing tax residency.
- Stress or pessimistic: lower-income, higher-expense, market drawdown, or delayed-cash scenarios.
- Optimistic: higher-income, lower-expense, stronger-return, or accelerated-savings scenarios.

Manual forecasting must remain useful without Hermes. Hermes improves scenario planning and recommendations, but Sure must still show a baseline and user-created manual scenarios if Hermes is unavailable.

## Manual Forecast Authoring

Users must be able to build and edit the forecast manually through the Sure UI. Hermes can accelerate planning by creating drafts and recommendations, but every underlying forecast object that affects the active forecast should also be user-authorable or user-editable without Hermes.

Manual UI authoring must support:

- Creating, editing, duplicating, archiving, and deleting scenarios.
- Toggling scenarios on and off.
- Moving scenario events on the timeline.
- Adding one-time income and expenses.
- Adding recurring planned forecast items.
- Adding future debt, debt drawdowns, debt payments, and savings events.
- Adding portfolio contributions and withdrawals.
- Adjusting projected category budgets by month.
- Setting and editing goals, including runway goals.
- Marking goals as hard blockers or soft targets.
- Classifying account liquidity.
- Linking forecast-only items to actual entries or transactions.
- Reviewing expected-vs-actual variance.
- Comparing baseline, downside, upside, and custom scenario stacks.

Hermes-created objects should use the same data model as manually created objects. The difference is source and approval state, not object shape. A Hermes-created draft scenario should become a normal editable scenario after user approval.

Life-event scenarios belong on the master timeline as scenario layers. They may contain many lower-level forecast effects:

- Income changes.
- Payroll timing changes.
- Housing cost changes.
- One-time moving costs.
- Currency and FX assumptions.
- Tax changes.
- Healthcare and insurance changes.
- Account or provider changes.
- Portfolio contribution changes.
- Debt repayment changes.
- New debt or growing debt assumptions.
- Emergency fund target changes.
- Country-specific cost-of-living changes.

Hermes is the preferred interface for developing these scenarios because it has broader personal context. Sure should still store the resulting structured effects as forecast scenario items so they remain visible, toggleable, editable, and testable.

## Hermes Integration

Preferred integration is both push and pull:

- Sure pushes scheduled forecast packets to Hermes for weekly review and triggered analysis.
- Hermes can pull extra Sure context through the existing Sure plugin/MCP tooling when deeper analysis is needed.

The system should start with Sure pushing structured forecast packets. This creates repeatable weekly reviews and saved forecast records while keeping Hermes as the reasoning layer. Hermes can also pull extra context through Sure MCP/plugin tools when analysis requires it.

The forecast packet should be structured JSON, not an unstructured prompt only. It should include:

- Forecast run metadata.
- Family currency and date range.
- Current balances.
- Current budget and projected monthly budget values.
- Recurring transaction summary.
- One-time forecast events.
- Debt and savings assumptions.
- Portfolio holdings, performance, and market-close movement summary.
- Scenario definitions.
- Risk flags generated deterministically by Sure.
- Specific questions for Hermes to answer.

Hermes response should be stored separately from deterministic forecast data. A bad or incomplete Hermes response must not corrupt the baseline forecast.

## Weekly Review Workflow

The product should support a weekly financial review.

At a high level:

1. Market data imports at market close using Sure's existing market data path.
2. Sure generates or refreshes the 0-36 month forecast.
3. Sure detects significant changes in cashflow, budget trajectory, portfolio value, holdings, market prices, debt, or scenario assumptions.
4. Sure sends a forecast packet to Hermes.
5. Hermes returns scenario interpretation, recommendations, and follow-up questions.
6. Sure stores the review and renders it in the forecasting UI.

The weekly review should separate:

- Facts from Sure.
- Assumptions from forecast settings.
- Deterministic risks from the forecast engine.
- Hermes interpretation.
- User-approved scenario changes.

## Visualization Requirements

Forecasting should be visual and inspectable.

Likely views:

- Budget forecast grid by month and category.
- Scenario comparison chart.
- Cash runway chart.
- Net worth projection chart.
- Portfolio contribution and market movement panel.
- Deterministic scenario bands for baseline, downside, upside, and custom stacks.
- One-time event timeline.
- Weekly review summary.

The UI should build on the existing budgets route and design system. UI work must use Sure's design-system rules: functional tokens, `DS::*` primitives where available, `icon` helper for icons, and localized strings.

## Initial Data Model Sketch

Model names below are the target names for implementation planning; exact column names and types will be finalized in the implementation plan.

`ForecastRun`

- Belongs to `family` and optionally `user`.
- Stores generated-at timestamp, horizon dates, source version metadata, assumption snapshot, schema versions, active scenario snapshot, goal snapshot, liquidity snapshot, and baseline summary.
- Has many generated forecast months, generated projections, event links, and reviews.
- Does not own editable scenarios; it snapshots the scenarios and assumptions that were active when the run was generated.

`ForecastScenario`

- Belongs to `family`.
- Types: baseline, manual, hermes_suggested, market_triggered, life_event, stress, optimistic.
- Stores name, description, status, source, assumptions JSON, approval state, active state, display order, confidence, and effective date range.
- Can be toggled on or off as a forecast layer.
- Can stack with other active scenarios.
- Hermes-created scenarios start as drafts and must be approved before becoming active.

`ForecastMonth`

- Belongs to forecast run.
- Represents one generated projected month for a named scenario stack, such as baseline, downside, upside, or custom.
- Stores scenario stack key, active scenario snapshot, expected income, expected spending, cash balance, net worth, portfolio value, debt balance, savings, and confidence metadata.
- Records source-layer contribution metadata so users can trace which scenarios affected the month.

`ForecastCategoryProjection`

- Belongs to forecast month and category.
- Stores category-level planned, projected, actual-to-date, and variance values.
- Records whether the value was inherited from a budget, generated from recurring transactions, overridden manually, or supplied by an active scenario layer.

`ForecastEvent`

- Belongs to family and optionally scenario.
- Represents forecast-only planned financial items, including one-time income, one-time expense, transfer, debt payment, new debt, debt drawdown, savings contribution, portfolio contribution/withdrawal, or recurring expected item.
- Stores date or recurrence rule, amount, currency, category/account linkage, confidence, source, lifecycle status, timeline position, effect type, and notes.
- Effect types include additive and override.
- Can optionally link to one or more future real entries/transactions once they arrive.
- Supports variance analysis after linking.

`ForecastDebtProjection`

- Belongs to forecast month and optionally account.
- Represents projected debt state for existing liabilities or hypothetical future debt.
- Stores opening balance, new principal, accrued interest, minimum payment, planned extra payment, closing balance, interest rate assumptions, payoff estimate, source, and source-layer contribution metadata.
- Supports growing debt balances where new charges, interest, or drawdowns exceed payments.

`ForecastEventLink`

- Belongs to a forecast event and an actual entry or transaction.
- Stores link source, match confidence, linked amount, linked date, and status.
- Allows a single forecast item to match multiple real transactions, or multiple planned events to be resolved manually if needed.

`ForecastGoal`

- Belongs to family and optionally scenario.
- Stores goal type, target amount or duration, currency, target date, status, source, required flag, and blocking behavior.
- First goal types include minimum cash buffer, minimum cash runway duration, scenario-specific runway duration, monthly savings target, debt payoff target, portfolio contribution target, and life-event readiness target.
- Can be global or scenario-specific.
- Can gate scenario feasibility without being a scenario itself.

`ForecastGoalEvaluation`

- Belongs to forecast month or forecast run, and references a forecast goal.
- Stores scenario stack key, evaluation status, observed value, target value, shortfall or surplus, and blocking result.
- Explains why a scenario stack is feasible, at risk, blocked, or unknown.

`ForecastAccountLiquiditySetting`

- Belongs to family and account.
- Stores liquidity class and optional scenario override.
- Allows default liquidity treatment to be overridden without changing the underlying account.

`ForecastReview`

- Belongs to forecast run.
- Stores Hermes response, deterministic flags, triggered reason, status, user-visible summary, and draft recommendations or scenario suggestions.

This model is the implementation-planning baseline. The next plan should convert these concepts into exact migrations, model validations, indexes, service objects, and tests.

## Design Defaults For Implementation Planning

- Route placement: use `/forecast` as the dedicated workspace, with links from `budgets#show` and `budget_categories#index`.
- Material market movement: start with configurable thresholds based on portfolio day change, holding-level day change, and goal impact; implementation planning should choose defaults.
- Debt amortization inputs: principal, interest rate, accrual cadence, minimum payment, due date, extra payment assumptions, and effective-rate periods.
- Full workspace charts: cash runway, monthly budget projection, scenario stack comparison, net worth projection, portfolio movement, debt projection, goal status, and forecast-event timeline.

## Deferred Or Explicitly Separate Work

- True streaming or intraday market data.
- Fully automated scenario changes without user review.
- Replacing existing Sure budgets.
- Building a separate app outside this fork.
- Allowing Hermes output to mutate baseline forecast data directly.

These are deferred or separate because they conflict with the chosen product boundary, not because the goal is a small MVP. The target product can still be broad inside the 0-36 month personal forecasting horizon.

## Implementation Plan Must Detail

- Detailed migrations and model validations.
- Forecast engine formulas and deterministic risk flags.
- Hermes packet and response schema.
- Weekly review trigger rules.
- Debt-account interest accrual prerequisite design.
- Market-close movement thresholds.
- Timeline workspace layout.
- Test strategy.
