# frozen_string_literal: true

require "test_helper"

# Unit tests for the Assumption Type Registry — the single server-side catalog
# every assumption kind must be registered in before it can be saved, rendered,
# or expanded (spec "Assumption Type Registry Contract"). The registry is the one
# source of truth the engine, the assumptions controller, and the assumption
# group read model all resolve through; these tests lock its contract.
class Forecasts::Assumptions::RegistryTest < ActiveSupport::TestCase
  Registry = Forecasts::Assumptions::Registry

  test "ships the MVP kinds in deterministic group order" do
    assert_equal %w[salary living_expense], Registry.kinds
  end

  test "registered? is true for shipped kinds and false otherwise" do
    assert Registry.registered?("salary")
    assert Registry.registered?("living_expense")
    refute Registry.registered?("transfer")
    refute Registry.registered?("")
    refute Registry.registered?(nil)
  end

  test "resolves the expander class per kind" do
    assert_equal Forecasts::Projection::Expanders::Salary, Registry.expander_for("salary")
    assert_equal Forecasts::Projection::Expanders::LivingExpense, Registry.expander_for("living_expense")
    assert_nil Registry.expander_for("transfer")
  end

  test "resolves the typed form class per kind" do
    assert_equal Forecasts::Assumptions::SalaryForm, Registry.form_class_for("salary")
    assert_equal Forecasts::Assumptions::LivingExpenseForm, Registry.form_class_for("living_expense")
    assert_nil Registry.form_class_for("transfer")
  end

  test "resolves the params class per kind" do
    assert_equal Forecasts::Assumptions::SalaryParams, Registry.entry("salary").params_class
    assert_equal Forecasts::Assumptions::LivingExpenseParams, Registry.entry("living_expense").params_class
  end

  test "resolves the rail icon per kind and falls back to the neutral default" do
    assert_equal "briefcase", Registry.icon_for("salary")
    assert_equal "shopping-cart", Registry.icon_for("living_expense")
    assert_equal Registry::DEFAULT_ICON, Registry.icon_for("transfer")
  end

  test "resolves a locale scope per kind" do
    assert_equal "forecasts.assumptions.salary", Registry.locale_scope_for("salary")
    assert_equal "forecasts.assumptions.living_expense", Registry.locale_scope_for("living_expense")
    assert_nil Registry.locale_scope_for("transfer")
  end

  test "order_for keeps known kinds ahead of unknown kinds" do
    assert Registry.order_for("salary") < Registry.order_for("living_expense")
    assert Registry.order_for("living_expense") < Registry.order_for("transfer")
  end

  test "preview_for is true only for kinds that ship a JS preview-engine mirror" do
    # Both MVP kinds are linear cash flows the JS engine mirrors exactly.
    assert Registry.preview_for("salary")
    assert Registry.preview_for("living_expense")
    assert Registry.preview_for(:salary)
    # Unknown kinds never preview — false, never nil, so callers can emit the
    # flag straight into the island JSON.
    assert_equal false, Registry.preview_for("transfer")
    assert_equal false, Registry.preview_for(nil)
  end

  test "entry! raises a typed error for an unknown kind" do
    assert_kind_of Forecasts::Assumptions::Registry::Entry, Registry.entry!("salary")

    assert_raises(Forecasts::Assumptions::Registry::UnknownKindError) do
      Registry.entry!("transfer")
    end
  end

  test "accepts a symbol kind" do
    assert Registry.registered?(:salary)
    assert_equal "briefcase", Registry.icon_for(:salary)
  end

  test "every registered form class declares the same kind it is keyed under" do
    Registry::ENTRIES.each do |entry|
      assert_equal entry.kind, entry.form_class.assumption_kind,
        "#{entry.form_class} must declare assumption_kind #{entry.kind.inspect}"
    end
  end
end
