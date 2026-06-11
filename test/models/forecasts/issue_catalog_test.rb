require "test_helper"

# Locks the Forecast V2 issue-code contract: every code the IssueCatalog maps
# (and every remediation action it lists) must resolve to localized copy, so the
# IssuePanel never renders a raw engine key as a user-facing title or button. The
# F9 registry fix added engine-emitted codes (unknown_assumption_kind,
# invalid_milestone_reference) whose titles/actions were initially missing — this
# test prevents that drift from recurring on the server side.
class Forecasts::IssueCatalogTest < ActiveSupport::TestCase
  # Codes the engine emits that MUST be catalogued (so the panel resolves their
  # severity + actions, not the DEFAULT_SEVERITY fallback).
  ENGINE_EMITTED_CODES = %w[
    missing_fx_rate
    invalid_assumption_params
    invalid_milestone_reference
    unknown_assumption_kind
  ].freeze

  test "every catalogued code has a localized issue title" do
    Forecasts::IssueCatalog::ENTRIES.each_key do |code|
      key = "forecasts.issues.#{code}"
      assert I18n.exists?(key), "missing locale title #{key} for issue code #{code}"
    end
  end

  test "every catalogued remediation action has a localized button label" do
    Forecasts::IssueCatalog::ENTRIES.each do |code, entry|
      entry[:actions].each do |action|
        key = "forecasts.issue_panel.action_#{action}"
        assert I18n.exists?(key),
          "missing locale label #{key} for action #{action} on issue #{code}"
      end
    end
  end

  test "engine-emitted issue codes are all catalogued" do
    ENGINE_EMITTED_CODES.each do |code|
      assert Forecasts::IssueCatalog::ENTRIES.key?(code),
        "engine emits #{code} but IssueCatalog has no entry, so the panel would " \
        "fall back to the default severity instead of the engine-intended one"
    end
  end
end
