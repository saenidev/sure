require "application_system_test_case"

# THROWAWAY browser evidence for the Forecast V2 Inertia/Vite spike (slice A7).
#
# Proves the viability gates the spike blueprint demands ("Browser Evidence" +
# "Pass Criteria"):
#
#   - The route mounts in an authenticated Rails session and the React+TS Inertia
#     page actually hydrates in the browser (not just an SSR string).
#   - The page shows the plan label and a metric value from the typed props.
#   - The selected period moves under BOTH keyboard (arrow keys) and pointer
#     (pointermove) input, and the active marker + selected metric value update.
#   - NO network requests fire during pointer movement — the chart scrub is purely
#     local (the core Inertia-path rule: Turbo/Stimulus/server never owns scrub
#     state). A browser-side network probe enforces this.
#   - An existing, non-forecast Rails page (transactions) still renders after the
#     Vite/Inertia integration, proving no regression in the importmap/Turbo
#     surface.
#
# Delete with the ForecastV2SpikeController, its Inertia page, and the controller
# test when the spike is folded into Phase 2 or removed.
class ForecastV2InertiaSpikeTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "renders the React Inertia page with the plan label and a metric value" do
    visit forecast_v2_spike_path

    # The page only exists once React hydrates the Inertia mount — a bare SSR
    # string would not produce the interactive scrub region below.
    assert_selector "[data-testid='forecast-spike-page']"

    plan_label = find("[data-testid='forecast-plan-label']")
    assert plan_label.text.present?, "expected the plan label to render from props"

    within "[data-testid='forecast-metric-strip']" do
      assert_selector "dd", minimum: 1
      assert_match(/\d/, first("dd").text, "expected a metric value to render from props")
    end

    # The local D3 scrub region (and its marker) must mount client-side.
    assert_selector "[data-testid='forecast-scrub-region']"
    assert_selector "[data-testid='forecast-scrub-marker']"
  end

  test "moves the selected period via keyboard and pointer and updates the marker without network" do
    visit forecast_v2_spike_path

    assert_selector "[data-testid='forecast-spike-page']"
    region = find("[data-testid='forecast-scrub-region']")

    initial = scrub_state
    assert initial[:value].present?, "expected an initial selected metric value"
    assert initial[:markerCx].present?, "expected an initial marker position"

    # --- Keyboard period selection -----------------------------------------
    region.click # focus the slider region
    region.send_keys(:end) # jump to the last period
    assert_keyboard_moved_from(initial)
    after_keyboard = scrub_state

    # --- Pointer scrub with a browser-side network probe -------------------
    install_network_probe

    # Move the pointer across the scrub region: from far right back toward the
    # left. The nearest-period math must re-select a different period purely on
    # the preloaded scale.
    dispatch_pointer_move(region, ratio: 0.05)
    assert_value_changed_from(after_keyboard[:value])
    after_pointer = scrub_state

    # A second pointer move to confirm the marker keeps tracking the pointer.
    dispatch_pointer_move(region, ratio: 0.95)
    assert_value_changed_from(after_pointer[:value])

    # The whole point of the Inertia spike: pointer movement is local. No fetch,
    # no XHR, no Inertia visit may fire while scrubbing.
    assert_equal 0, network_request_count,
      "expected ZERO network requests during pointer movement (local scrub)"
  end

  test "an existing non-forecast Rails page still renders after Vite/Inertia integration" do
    visit transactions_url

    # The importmap/Turbo surface must be unaffected by adding the Vite/Inertia
    # forecast entrypoint and dedicated layout.
    assert_selector "h1", text: "Transactions"
  end

  private
    # Read the current scrub selection straight from the DOM the React page
    # rendered: the displayed value, the marker's X coordinate, and the slider's
    # aria-valuenow (the selected period index). Returns symbol-keyed values.
    def scrub_state
      raw = page.evaluate_script(<<~JS)
        (() => {
          const region = document.querySelector("[data-testid='forecast-scrub-region']");
          const value = document.querySelector("[data-testid='forecast-scrub-value']");
          const marker = document.querySelector("[data-testid='forecast-scrub-marker']");
          return {
            value: value ? value.textContent.trim() : null,
            valueNow: region ? region.getAttribute("aria-valuenow") : null,
            valueText: region ? region.getAttribute("aria-valuetext") : null,
            markerCx: marker ? marker.getAttribute("cx") : null
          };
        })()
      JS
      raw.transform_keys(&:to_sym)
    end

    # Assert the keyboard interaction actually moved the selected period (the
    # aria-valuenow index changed and the value or marker changed too).
    def assert_keyboard_moved_from(before)
      assert_changes_in_scrub(before, "keyboard")
    end

    def assert_changes_in_scrub(before, via)
      moved = false
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          now = scrub_state
          moved = now[:valueNow] != before[:valueNow] || now[:value] != before[:value]
          break if moved
          sleep 0.05
        end
      end
      assert moved, "expected the selected period to change via #{via}"
    end

    # Wait for the displayed metric value to differ from a known prior value.
    def assert_value_changed_from(previous_value)
      changed = false
      Timeout.timeout(Capybara.default_max_wait_time) do
        loop do
          changed = scrub_state[:value] != previous_value
          break if changed
          sleep 0.05
        end
      end
      assert changed, "expected the selected metric value to change (was #{previous_value.inspect})"
    end

    # Install a browser-side probe that counts every network egress path the
    # scrub could conceivably trigger: fetch, XMLHttpRequest, sendBeacon, and
    # Inertia client visits. Resets the counter so only post-install traffic is
    # measured.
    def install_network_probe
      page.execute_script(<<~JS)
        (() => {
          window.__scrubNetCount = 0;
          const bump = () => { window.__scrubNetCount += 1; };

          const realFetch = window.fetch;
          window.fetch = function (...args) { bump(); return realFetch.apply(this, args); };

          const realOpen = window.XMLHttpRequest.prototype.open;
          window.XMLHttpRequest.prototype.open = function (...args) { bump(); return realOpen.apply(this, args); };

          if (navigator.sendBeacon) {
            const realBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function (...args) { bump(); return realBeacon.apply(this, args); };
          }

          // Inertia client visits emit `inertia:start` before issuing a request.
          document.addEventListener("inertia:start", bump);
        })()
      JS
    end

    def network_request_count
      page.evaluate_script("window.__scrubNetCount").to_i
    end

    # Dispatch a real PointerEvent at a fractional X position across the scrub
    # region (ratio in [0, 1]). The component's onPointerMove maps clientX to the
    # nearest period, so this exercises the exact local scrub code path a mouse
    # drag would.
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
