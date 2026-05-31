require "test_helper"

class Forecast::AccountLiquiditySettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @family.forecast_account_liquidity_settings.delete_all
    @family.forecast_scenarios.delete_all
    @scenario = @family.forecast_scenarios.create!(name: "Base", status: "active")
    sign_in @user
  end

  # --- index -----------------------------------------------------------------

  test "new renders the form inside the modal turbo frame" do
    get new_forecast_account_liquidity_setting_url(account_id: @account.id), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  test "edit renders the form inside the modal turbo frame" do
    setting = @family.forecast_account_liquidity_settings.create!(account: @account, liquidity_class: "cash")

    get edit_forecast_account_liquidity_setting_url(setting), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal", count: 1
    assert_select "turbo-frame#modal form[data-turbo-frame=?]", "_top"
  end

  test "index lists the family's visible accounts with their classification" do
    get forecast_account_liquidity_settings_path

    assert_response :success
    assert_select "[data-testid=liquidity-summary]"
    assert_select "##{dom_id(@account, :liquidity)}"
  end

  test "index renders override and edit triggers as GET modal links, not POST forms" do
    get forecast_account_liquidity_settings_path

    assert_response :success

    new_path = new_forecast_account_liquidity_setting_path(account_id: @account.id)
    modal_link_hrefs = css_select("a[data-turbo-frame=modal]").map { |a| a["href"] }

    assert_includes modal_link_hrefs, new_path

    form_actions = css_select("form").map { |f| f["action"] }
    assert_not_includes form_actions, new_path

    setting = @family.forecast_account_liquidity_settings.create!(account: @account, liquidity_class: "cash")
    get forecast_account_liquidity_settings_path

    assert_response :success

    edit_path = edit_forecast_account_liquidity_setting_path(setting)
    modal_link_hrefs = css_select("a[data-turbo-frame=modal]").map { |a| a["href"] }
    assert_includes modal_link_hrefs, edit_path

    form_actions = css_select("form").map { |f| f["action"] }
    assert_not_includes form_actions, edit_path
  end

  test "index renders an empty list when the family has no accounts" do
    empty_user = users(:empty)
    sign_in empty_user

    get forecast_account_liquidity_settings_path

    assert_response :success
    assert_select "[data-testid=liquidity-empty-state]"
  end

  # --- create happy path -----------------------------------------------------

  test "create persists a liquidity setting scoped to the current family" do
    assert_difference "@family.forecast_account_liquidity_settings.count", 1 do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: @account.id,
          liquidity_class: "restricted"
        }
      }
    end

    assert_redirected_to forecast_account_liquidity_settings_path
    setting = @family.forecast_account_liquidity_settings.order(:created_at).last
    assert_equal @account.id, setting.account_id
    assert_equal "restricted", setting.liquidity_class
    assert_equal @family.id, setting.family_id
  end

  test "create with a scenario scope and date window persists" do
    assert_difference "@family.forecast_account_liquidity_settings.count", 1 do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: @account.id,
          liquidity_class: "liquid",
          forecast_scenario_id: @scenario.id,
          starts_on: Date.current.to_s,
          ends_on: (Date.current + 30.days).to_s
        }
      }
    end

    setting = @family.forecast_account_liquidity_settings.order(:created_at).last
    assert_equal @scenario.id, setting.forecast_scenario_id
  end

  # --- create validation / failure surfacing (422) ---------------------------

  test "an overlapping window for the same account and scenario is rejected with a 422" do
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "cash",
      starts_on: Date.current,
      ends_on: Date.current + 30.days
    )

    assert_no_difference "@family.forecast_account_liquidity_settings.count" do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: @account.id,
          liquidity_class: "restricted",
          starts_on: (Date.current + 10.days).to_s,
          ends_on: (Date.current + 40.days).to_s
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "ends_on before starts_on is rejected with a 422" do
    assert_no_difference "@family.forecast_account_liquidity_settings.count" do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: @account.id,
          liquidity_class: "cash",
          starts_on: Date.current.to_s,
          ends_on: (Date.current - 5.days).to_s
        }
      }
    end

    assert_response :unprocessable_entity
  end

  # --- create cannot set family_id via params --------------------------------

  test "create ignores a family_id passed in params" do
    other_family = families(:empty)

    post forecast_account_liquidity_settings_path, params: {
      forecast_account_liquidity_setting: {
        account_id: @account.id,
        liquidity_class: "cash",
        family_id: other_family.id
      }
    }

    assert_redirected_to forecast_account_liquidity_settings_path
    setting = @family.forecast_account_liquidity_settings.order(:created_at).last
    assert_equal @family.id, setting.family_id
  end

  # --- authorization: foreign account / scenario / record --------------------

  test "a liquidity setting for an account not in the family is denied with a 404" do
    foreign_account = accounts(:other_asset)
    foreign_account.update!(family: families(:empty), owner: users(:empty))

    assert_no_difference "ForecastAccountLiquiditySetting.count" do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: foreign_account.id,
          liquidity_class: "cash"
        }
      }
    end

    assert_response :not_found
  end

  test "a foreign scenario id is rejected by the model with a 422" do
    foreign_scenario = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "@family.forecast_account_liquidity_settings.count" do
      post forecast_account_liquidity_settings_path, params: {
        forecast_account_liquidity_setting: {
          account_id: @account.id,
          liquidity_class: "cash",
          forecast_scenario_id: foreign_scenario.id
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "edit on another family's setting is denied with a 404" do
    foreign = build_foreign_setting

    get edit_forecast_account_liquidity_setting_path(foreign)

    assert_response :not_found
  end

  test "update on another family's setting is denied with a 404" do
    foreign = build_foreign_setting

    patch forecast_account_liquidity_setting_path(foreign), params: {
      forecast_account_liquidity_setting: { liquidity_class: "illiquid" }
    }

    assert_response :not_found
    assert_equal "cash", foreign.reload.liquidity_class
  end

  test "destroy on another family's setting is denied with a 404" do
    foreign = build_foreign_setting

    assert_no_difference "ForecastAccountLiquiditySetting.count" do
      delete forecast_account_liquidity_setting_path(foreign)
    end

    assert_response :not_found
  end

  # --- update / destroy happy paths ------------------------------------------

  test "update changes the liquidity class on the current family's setting" do
    setting = @family.forecast_account_liquidity_settings.create!(account: @account, liquidity_class: "cash")

    patch forecast_account_liquidity_setting_path(setting), params: {
      forecast_account_liquidity_setting: { liquidity_class: "illiquid" }
    }

    assert_redirected_to forecast_account_liquidity_settings_path
    assert_equal "illiquid", setting.reload.liquidity_class
  end

  test "destroy removes the current family's setting" do
    setting = @family.forecast_account_liquidity_settings.create!(account: @account, liquidity_class: "cash")

    assert_difference "@family.forecast_account_liquidity_settings.count", -1 do
      delete forecast_account_liquidity_setting_path(setting)
    end

    assert_redirected_to forecast_account_liquidity_settings_path
  end

  private
    def build_foreign_setting
      foreign_family = families(:empty)
      foreign_account = accounts(:other_asset)
      foreign_account.update!(family: foreign_family, owner: users(:empty))
      foreign_family.forecast_account_liquidity_settings.create!(
        account: foreign_account,
        liquidity_class: "cash"
      )
    end
end
