require "application_system_test_case"
require "fileutils"
require Rails.root.join("test/fixtures/files/forecasts/proof_slice_seed")

# Forecast V2 MANDATORY END-TO-END PROOF SLICE (slice C9).
#
# This is the product/architecture gate the spec ("Mandatory End-To-End Proof
# Slice", "Proof-slice exit gate", "Screenshot Baseline Matrix") requires before
# Phase 4 capability work can start. It drives the REAL `/forecast` route with the
# V2 flag ON for a connected family and proves, in a real browser:
#
#   1. First viewport renders the V2 plan SHELL straight from preloaded props —
#      chart, selected period (marker + metric strip), assumption groups, issues,
#      and explanation — with NO "generate forecast" gate.
#   2. Selecting a period updates the marker / metrics / active assumptions /
#      explanation / issue state with ZERO network requests during pointer
#      movement (a browser-side fetch/XHR/beacon/inertia probe enforces this).
#   3. Opening the salary editor preserves plan / selected period / scenario stack
#      (the drawer renders OVER the workspace; the store keeps that state).
#   4. Saving shows committed card state + a fresh (or stale/recomputing-then-fresh)
#      projection, patching ONLY scoped regions: the document is never replaced
#      (no full-page navigation) and the workspace shell node is the SAME element
#      (no full workspace re-render), with a single scoped PATCH and no full
#      Inertia page visit.
#   5. The issue-limited state (missing FX seeded) renders a STRUCTURED issue
#      inside the plan shell — localized copy, no raw UUID — while the plan shell
#      stays visible.
#
# It also captures the desktop + mobile screenshot baselines the Screenshot
# Baseline Matrix needs (populated, selected-period, salary editor, saving,
# issue-limited) under a stable output path so UX reviews can diff iterations.
class ForecastV2ProofSliceTest < ApplicationSystemTestCase
  # Stable artifact path the Screenshot Baseline Matrix / UX review protocol read
  # from. Kept out of the repo (output/ is gitignored), reviewed as a baseline.
  SCREENSHOT_DIR = Rails.root.join("output/playwright")

  MOBILE_WIDTH = 390
  MOBILE_HEIGHT = 844

  setup do
    @user = users(:family_admin)
    @family = @user.family

    enable_forecast_v2_for(@family)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
  end

  teardown do
    restore_forecast_v2_flag
  end

  # --- (1) + (2) + (3) + (4): the populated happy-path proof + baselines --------

  test "first viewport, period change (no network), salary editor, and scoped save on the real /forecast route" do
    seed_populated_plan
    sign_in @user

    visit forecast_url

    # (1) FIRST VIEWPORT: the V2 plan shell renders from preloaded props, with no
    # "generate forecast" gate. Every first-viewport region is present.
    assert_selector "[data-testid='forecast-plan-shell']"
    assert_selector "[data-testid='forecast-plan-name']"
    assert_selector "[data-testid='forecast-projection-chart']"
    assert_selector "[data-testid='forecast-metric-strip']"
    assert_selector "[data-testid='forecast-selected-period']"
    assert_selector "[data-testid='forecast-assumption-groups']"
    assert_selector "[data-testid='forecast-issue-panel']"
    # A derived salary + living-expense card prove the default plan bootstrapped.
    assert_selector "[data-card-kind='salary']"
    assert_selector "[data-card-kind='living_expense']"
    # No generate gate: the V2 surface never shows a primary "Generate forecast".
    assert_no_button(text: /generate/i)
    refute_includes page.text.downcase, "generate forecast"

    # The seeded selected period drives the chart marker + the metric strip.
    assert_selector "[data-testid='forecast-chart-marker']"
    assert_selector "[data-testid='forecast-metric-strip'] dd", minimum: 1

    capture(:populated)

    # (2) PERIOD CHANGE WITH NO NETWORK: scrubbing the chart re-selects a period
    # purely on the preloaded scale. Install a network probe, scrub, and assert the
    # marker/value moved with ZERO network egress during pointer movement.
    scrubber = find("[data-testid='forecast-chart-scrubber']")
    initial = chart_state

    scrubber.click # focus the slider
    scrubber.send_keys(:end) # jump to the last period via keyboard
    wait_until_chart_changed(initial)
    after_keyboard = chart_state

    install_network_probe
    # Scrub to the far left (an early period), then back toward the right (a later
    # period). Track the selected period INDEX (aria-valuenow) — it is monotonic
    # with pointer position, so it reliably changes even if two periods happen to
    # share a displayed metric value.
    dispatch_pointer_move(scrubber, ratio: 0.02)
    wait_until_period_index_changed(after_keyboard[:valueNow])
    after_first_move = chart_state[:valueNow]
    dispatch_pointer_move(scrubber, ratio: 0.98)
    wait_until_period_index_changed(after_first_move)

    # The marker + displayed value tracked the pointer (selection actually moved).
    refute_nil chart_state[:markerCx], "expected the marker to track the scrub"
    refute_nil chart_state[:value], "expected a selected metric value"

    assert_equal 0, network_request_count,
      "expected ZERO network requests during pointer scrub (local-only selection)"

    capture(:selected_period)

    # (3) SALARY EDITOR PRESERVES PLAN / PERIOD / SCENARIO. Record the workspace
    # context before opening, open the drawer, and assert nothing changed.
    period_before = chart_state[:valueNow]
    plan_id_before = shell_attr("data-plan-id")
    scenario_before = shell_attr("data-scenario-stack-key")

    open_salary_editor
    assert_selector "[data-testid='forecast-assumption-editor']"
    assert_selector "[data-testid='forecast-assumption-editor-form']"

    assert_equal plan_id_before, shell_attr("data-plan-id"),
      "opening the editor must not change the plan"
    assert_equal scenario_before, shell_attr("data-scenario-stack-key"),
      "opening the editor must preserve the scenario stack"
    assert_equal period_before, chart_state[:valueNow],
      "opening the editor must preserve the selected period"

    capture(:salary_editor)

    # (4) SCOPED SAVE — no full reload, no full workspace replacement.
    #
    # Tag the live document + the workspace shell node so a full-page navigation
    # (document replaced) or a full workspace re-render (shell node replaced) is
    # detectable after the save.
    tag_document_and_shell

    amount_before = salary_primary_line
    fill_in_salary_editor(amount: "8500")

    install_network_probe
    find("[data-testid='forecast-assumption-editor-save']").click

    # The committed save closes the drawer and patches scoped regions.
    assert_no_selector "[data-testid='forecast-assumption-editor']"

    # Committed card state: the salary card reflects the new server-truth amount.
    wait_until_salary_line_changed(amount_before)
    assert_includes salary_primary_line, "8,500"

    # Projection freshness shows a settled state (fresh within budget, or
    # recomputing then fresh) — never a generate gate.
    assert_selector "[data-testid='forecast-freshness']"
    freshness_state = find("[data-testid='forecast-freshness']")["data-freshness-state"]
    assert_includes %w[fresh recomputing stale], freshness_state

    # Scoped patch, NOT a full page navigation and NOT a full workspace replace:
    # the tagged document + shell node survive the save.
    assert document_marker_survived?,
      "a save must NOT trigger a full-page navigation (Inertia partial patch only)"
    assert shell_node_survived?,
      "a save must patch scoped regions, NOT replace the whole workspace tree"

    # And the save issued network traffic (the PATCH) but no full Inertia page
    # visit replacing the workspace — a scoped JSON patch only.
    assert network_request_count >= 1, "expected the save to issue the scoped PATCH"
    assert_equal 0, inertia_visit_count,
      "the save must not trigger a full Inertia page visit (scoped patch only)"

    capture(:saving)
  end

  # --- (5) issue-limited state --------------------------------------------------

  test "issue-limited state renders a structured issue inside the plan shell (no raw UUID)" do
    seed_missing_fx_plan
    sign_in @user

    visit forecast_url

    # The plan shell stays visible — a limited state never hides the workspace.
    assert_selector "[data-testid='forecast-plan-shell']"
    assert_selector "[data-testid='forecast-projection-chart']"
    assert_selector "[data-testid='forecast-assumption-groups']"

    # The missing-FX issue renders as a STRUCTURED issue (stable code testid),
    # inside the issue panel, with a localized human title + remediation actions.
    panel = find("[data-testid='forecast-issue-panel']")
    assert panel["data-issue-count"].to_i >= 1, "expected at least one limiting issue"
    assert_selector "[data-testid='forecast-issue-missing_fx_rate']"
    within "[data-testid='forecast-issue-missing_fx_rate']" do
      # Localized human title (from the issue message_key), not the raw code.
      assert_text "Missing exchange rate"
      # Localized remediation action, not a raw action code.
      assert_text "Fetch rates"
    end

    # The raw engine code is NEVER the visible copy (it stays a non-visible
    # identifier on the testid only). The human title is shown instead.
    refute_match(/\bmissing_fx_rate\b/, panel.text,
      "the issue panel must not show the raw engine code as visible copy")

    # NO raw UUID anywhere in the rendered issue surface (privacy contract:
    # "Raw UUIDs and engine-internal identifiers should not appear in user-facing
    # failures").
    refute_match UUID_PATTERN, panel.text,
      "the issue surface must not expose a raw UUID"

    capture(:issue_limited)
  end

  private
    UUID_PATTERN = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i

    # --- Seeding ----------------------------------------------------------------

    def seed_populated_plan
      Forecasts::ProofSliceSeed.build(
        family: @family,
        account: accounts(:depository),
        budget: budgets(:one),
        as_of: Date.current
      )
    end

    def seed_missing_fx_plan
      Forecasts::ProofSliceSeed.seed_missing_fx(
        family: @family,
        account: accounts(:depository),
        budget: budgets(:one),
        as_of: Date.current
      )
    end

    # --- V2 flag ----------------------------------------------------------------

    # Enables the V2 surface for the test family at the canonical /forecast URL.
    # System tests run Puma in-process, so the in-memory config the predicate reads
    # is visible to the app under test.
    def enable_forecast_v2_for(family)
      @original_v2_enabled = Rails.configuration.x.forecast_v2.enabled
      @original_v2_family_ids = Rails.configuration.x.forecast_v2.family_ids
      Rails.configuration.x.forecast_v2.enabled = true
      Rails.configuration.x.forecast_v2.family_ids = [ family.id.to_s ].to_set.freeze
    end

    def restore_forecast_v2_flag
      return unless defined?(@original_v2_enabled)

      Rails.configuration.x.forecast_v2.enabled = @original_v2_enabled
      Rails.configuration.x.forecast_v2.family_ids = @original_v2_family_ids
    end

    # --- Screenshots ------------------------------------------------------------

    # Capture a desktop + mobile screenshot for one baseline state under the stable
    # output path. Resizes to a phone viewport for the mobile shot, then restores
    # the desktop viewport so the next interaction runs at desktop size.
    def capture(state)
      save_named_screenshot("forecast-v2-#{state}-desktop")

      page.current_window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
      save_named_screenshot("forecast-v2-#{state}-mobile")
    ensure
      page.current_window.resize_to(DEFAULT_VIEWPORT_WIDTH, DEFAULT_VIEWPORT_HEIGHT)
    end

    def save_named_screenshot(name)
      path = SCREENSHOT_DIR.join("#{name}.png").to_s
      page.save_screenshot(path)
    end

    # --- Chart selection state --------------------------------------------------

    # Read the chart's current selection straight from the DOM: the displayed
    # value, the scrubber's aria-valuenow (selected period index), and the marker's
    # X coordinate.
    def chart_state
      raw = page.evaluate_script(<<~JS)
        (() => {
          const scrubber = document.querySelector("[data-testid='forecast-chart-scrubber']");
          const value = document.querySelector("[data-testid='forecast-chart-value']");
          const marker = document.querySelector("[data-testid='forecast-chart-marker']");
          return {
            value: value ? value.textContent.trim() : null,
            valueNow: scrubber ? scrubber.getAttribute("aria-valuenow") : null,
            markerCx: marker ? marker.getAttribute("cx") : null
          };
        })()
      JS
      raw.transform_keys(&:to_sym)
    end

    def wait_until_chart_changed(before)
      moved = false
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          now = chart_state
          moved = now[:valueNow] != before[:valueNow] || now[:value] != before[:value]
          break if moved
          sleep 0.05
        end
      end
      assert moved, "expected the selected period to change"
    end

    def wait_until_period_index_changed(previous_index)
      changed = false
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          changed = chart_state[:valueNow] != previous_index
          break if changed
          sleep 0.05
        end
      end
      assert changed,
        "expected the selected period index to change (was #{previous_index.inspect})"
    end

    # --- Shell / save markers ---------------------------------------------------

    def shell_attr(name)
      find("[data-testid='forecast-plan-shell']")[name]
    end

    # Tag the live document and the workspace shell node so a full-page navigation
    # (document replaced) or full workspace re-render (shell node replaced) becomes
    # observable after the save.
    def tag_document_and_shell
      page.execute_script(<<~JS)
        window.__c9DocMarker = "alive";
        const shell = document.querySelector("[data-testid='forecast-plan-shell']");
        if (shell) { shell.dataset.c9ShellMarker = "alive"; }
      JS
    end

    def document_marker_survived?
      page.evaluate_script("window.__c9DocMarker === 'alive'")
    end

    def shell_node_survived?
      page.evaluate_script(<<~JS)
        (() => {
          const shell = document.querySelector("[data-testid='forecast-plan-shell']");
          return !!shell && shell.dataset.c9ShellMarker === "alive";
        })()
      JS
    end

    # --- Salary editor ----------------------------------------------------------

    def open_salary_editor
      within "[data-card-kind='salary']" do
        find("[data-testid^='forecast-assumption-edit-']").click
      end
      assert_selector "[data-testid='forecast-assumption-editor-form']"
    end

    def salary_primary_line
      find("[data-card-kind='salary'] p.privacy-sensitive").text
    end

    # Fill the salary editor with a complete, valid payload. The derived salary
    # carries no person/treatment params yet (the default plan only knows amount +
    # currency), so the proof-slice save fills the typed form's required fields the
    # way a user would before committing.
    def fill_in_salary_editor(amount:)
      find("[data-testid='forecast-editor-field-amount']").set(amount)
      find("[data-testid='forecast-editor-field-person_key']").set("primary")
      find("[data-testid='forecast-editor-field-gross_or_net']").find(:option, "Net").select_option
      find("[data-testid='forecast-editor-field-frequency']").find(:option, "Monthly").select_option
      find("[data-testid='forecast-editor-field-growth_policy']").find(:option, "No growth").select_option
    end

    def wait_until_salary_line_changed(before)
      changed = false
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          changed = salary_primary_line != before
          break if changed
          sleep 0.05
        end
      end
      assert changed, "expected the saved salary card to reflect the new amount"
    end

    # --- Network probe ----------------------------------------------------------

    # Count every network egress path + Inertia client visit so the scrub-network
    # and scoped-save assertions can prove what did (or did not) fire.
    def install_network_probe
      page.execute_script(<<~JS)
        (() => {
          window.__netCount = 0;
          window.__inertiaVisits = 0;
          const bump = () => { window.__netCount += 1; };

          const realFetch = window.fetch;
          window.fetch = function (...args) { bump(); return realFetch.apply(this, args); };

          const realOpen = window.XMLHttpRequest.prototype.open;
          window.XMLHttpRequest.prototype.open = function (...args) { bump(); return realOpen.apply(this, args); };

          if (navigator.sendBeacon) {
            const realBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function (...args) { bump(); return realBeacon.apply(this, args); };
          }

          // A full Inertia page visit emits `inertia:start`; a scoped fetch patch
          // does not. Counted separately so the save can prove "no full visit".
          document.addEventListener("inertia:start", () => { window.__inertiaVisits += 1; });
        })()
      JS
    end

    def network_request_count
      page.evaluate_script("window.__netCount").to_i
    end

    def inertia_visit_count
      page.evaluate_script("window.__inertiaVisits").to_i
    end

    # Dispatch a real PointerEvent at a fractional X position across the scrubber
    # region, exercising the exact local scrub code path a mouse drag would.
    def dispatch_pointer_move(region, ratio:)
      page.execute_script(<<~JS, region.native, ratio)
        (() => {
          const el = arguments[0];
          const ratio = arguments[1];
          const rect = el.getBoundingClientRect();
          const clientX = rect.left + rect.width * ratio;
          const clientY = rect.top + rect.height / 2;
          const event = new PointerEvent("pointermove", {
            bubbles: true,
            cancelable: true,
            clientX: clientX,
            clientY: clientY,
            pointerType: "mouse"
          });
          el.dispatchEvent(event);
        })()
      JS
    end
end
