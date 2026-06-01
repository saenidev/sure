# Forecast Budget Editor Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make forecast budget scenarios behave like reusable, carry-forward plans where saving only persists intentional month changes and templates capture the current edited month.

**Architecture:** Keep the existing Rails controller/view flow, but add explicit row edit semantics to the submitted form. The controller will clamp editable periods to the plan horizon, persist only rows marked as intentionally changed, and build templates from the same current row data used by the editor. UI changes stay in the existing forecast budget views and use design-system controls already present in the app.

**Tech Stack:** Rails 7, Minitest controller tests, ERB views, Stimulus for slider/input synchronization, existing `DS::*` components.

---

### Task 1: Regression Coverage For Intentional Row Persistence

**Files:**
- Modify: `test/controllers/forecast/budget_plans_controller_test.rb`

- [x] **Step 1: Write a failing test proving a no-op full-form save does not create exact amount rows**

Add a test that renders the same kind of full amount payload the browser submits, including inherited `expected_income`, inherited category spending, and zero uncategorized spending. The update should still save plan details, but `ForecastBudgetPlanAmount.count` must remain unchanged when no row is marked as changed.

- [x] **Step 2: Write a failing test proving only touched rows become change points**

Post the same full-form payload with a hidden row state marking `expected_income` as changed. Assert that only one `ForecastBudgetPlanAmount` exists and that unchanged inherited/category rows are not materialized.

- [x] **Step 3: Run the focused controller test and confirm failure**

Run: `bin/rails test test/controllers/forecast/budget_plans_controller_test.rb`

Expected before implementation: at least one new test fails because the controller currently saves every nonblank submitted amount row.

### Task 2: Regression Coverage For Templates, Horizon Navigation, Delete, And Labels

**Files:**
- Modify: `test/controllers/forecast/budget_plans_controller_test.rb`

- [x] **Step 1: Add a failing template test for live form submission**

Patch `forecast_budget_plan_path` with `commit: "save_template"` and a changed amount row. Assert a template is created from the posted value and the plan amount is also saved.

- [x] **Step 2: Add a failing edit render test for horizon navigation and accessible labels**

Render the first horizon month and assert there is no previous-month edit link outside the horizon. Assert amount and slider labels include row names such as `Forecast amount for Expected income` and `Adjust Expected income`.

- [x] **Step 3: Add an index render assertion for the delete/archive entry point**

Render index and assert each plan has a delete action using the existing `destroy` route.

- [x] **Step 4: Run the focused controller test and confirm failure**

Run: `bin/rails test test/controllers/forecast/budget_plans_controller_test.rb`

Expected before implementation: failures for template submit routing, horizon navigation, labels, or delete affordance.

### Task 3: Implement Explicit Row Edit Semantics

**Files:**
- Modify: `app/views/forecast/budget_plans/edit.html.erb`
- Modify: `app/javascript/controllers/forecast_budget_plan_form_controller.js`
- Modify: `app/controllers/forecast/budget_plans_controller.rb`

- [x] **Step 1: Add row state hidden inputs to the edit form**

Each amount row submits `mode`, `original_amount`, and the current `amount`. Rows start in `mode=inherited`, `mode=projected`, or `mode=exact` based on existing row state. This lets the server distinguish displayed inherited values from intentional overrides.

- [x] **Step 2: Update Stimulus to mark rows changed when amount or slider input changes**

The `syncAmount` and `syncSlider` actions set the matching hidden `mode` to `exact`. Totals continue updating from visible amount inputs.

- [x] **Step 3: Change `apply_amount_rows!` to persist only exact rows**

Rows with `mode=exact` create/update a `ForecastBudgetPlanAmount`. Rows with inherited/projected mode delete an existing exact row for that month, if present, and otherwise do nothing. Blank exact amounts delete the exact row.

### Task 4: Make Template Creation Use Current Editor Data

**Files:**
- Modify: `app/views/forecast/budget_plans/edit.html.erb`
- Modify: `app/controllers/forecast/budget_plans_controller.rb`

- [x] **Step 1: Move Save Template into the edit form**

Use a submit button with `name="commit"` and `value="save_template"` so unsaved row edits and scenario details are posted in the same request.

- [x] **Step 2: Branch update based on the submitted commit value**

After applying submitted details and amount rows, create a template when `commit` is the template action. Redirect to the budget plan index with the template notice.

- [x] **Step 3: Build templates from editor rows, not only persisted plan amounts**

Use the current row model after save so inherited budget values and projected values visible in the editor are captured. Persist one template amount per row.

### Task 5: Clamp Horizon Navigation And Improve UI Affordances

**Files:**
- Modify: `app/controllers/forecast/budget_plans_controller.rb`
- Modify: `app/views/forecast/budget_plans/edit.html.erb`
- Modify: `app/views/forecast/budget_plans/index.html.erb`
- Modify: `config/locales/views/forecasts/en.yml`

- [x] **Step 1: Clamp selected period to the plan horizon**

`set_period` should return the nearest valid custom month inside `horizon_start_on..horizon_end_on`.

- [x] **Step 2: Disable or omit previous/next links outside the horizon**

The edit view should not render an edit link for months before `horizon_start_on` or after `horizon_end_on`.

- [x] **Step 3: Add specific accessible labels**

Amount labels should include the row label. Slider labels should include the row label.

- [x] **Step 4: Add a delete/archive action to budget plan cards**

Use `DS::Button` with `method: :delete`, destructive styling, and confirmation text.

- [x] **Step 5: Clarify activation copy**

Keep activation/dependency metadata as notes for now, but make visible copy explicit that enforcement is scenario status/date window until condition evaluation exists.

### Task 6: Verification, Commit, And Push

**Files:**
- Verify all changed files with `git diff --check`.
- Run focused Rails tests.
- Commit only forecast budget files and this plan.
- Push `forecasting-foundation` to `origin`.

- [x] **Step 1: Run focused tests**

Run: `bin/rails test test/controllers/forecast/budget_plans_controller_test.rb test/models/forecast_budget_plan_test.rb test/models/forecast_budget_template_test.rb`

- [x] **Step 2: Run formatting/whitespace check**

Run: `git diff --check`

- [x] **Step 3: Inspect staged diff**

Stage only the plan, budget controller/view/JS/locales, and related tests. Confirm unrelated existing dirty files are not staged.

- [x] **Step 4: Commit and push**

Commit with an imperative message and push to `origin forecasting-foundation`.
