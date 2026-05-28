module Forecast
  class BudgetInputBuilder
    def initialize(family:, user:, periods:, money_converter:, scenario_ids:, included_account_scope:)
      @family = family
      @user = user
      @periods = periods
      @money_converter = money_converter
      @scenario_ids = Array(scenario_ids).compact_blank
      @included_account_scope = included_account_scope
    end

    def call
      before_count = Budget.count
      result = periods.map { |period| snapshot_for(period) }
      raise "Forecast budget input created real Budget rows" if Budget.count != before_count

      result
    end

    private
      attr_reader :family, :user, :periods, :money_converter, :scenario_ids, :included_account_scope

      def snapshot_for(period)
        source_budget = source_budget_for(period)
        overrides = budget_overrides_for(period)
        expected_income = source_budget ? money_converter.convert(amount: (source_budget.expected_income || 0).to_d, currency: source_budget.currency, source: "budget:#{source_budget.id}:expected_income") : nil
        income_override = latest_override(overrides, "expected_income")
        expected_income_override = income_override ? converted_override_amount(income_override) : nil
        uncategorized_override = latest_override(overrides, "uncategorized_spending")
        uncategorized_budgeted = uncategorized_override ? converted_override_amount(uncategorized_override) : nil
        actual_income = actual_income_for(period)
        uncategorized_actual = uncategorized_actual_spending_for(period)
        category_rows = categories_for(source_budget, period, overrides)

        {
          period_start_on: period.start_date,
          period_end_on: period.end_date,
          source_budget_id: source_budget&.id,
          currency: money_converter.currency,
          expected_income: expected_income_override&.amount || expected_income&.amount || 0.to_d,
          actual_income: actual_income.fetch(:amount),
          actual_uncategorized_spending: uncategorized_actual.fetch(:amount),
          budgeted_uncategorized_spending: uncategorized_budgeted&.amount || 0.to_d,
          uncategorized_actual_source_snapshot: uncategorized_actual.fetch(:source_snapshot),
          income_source_snapshot: {
            "budget_id" => source_budget&.id,
            "expected_income" => expected_income ? money_converter.snapshot_for(expected_income) : {},
            "expected_income_override" => expected_income_override ? override_snapshot(income_override, expected_income_override) : {},
            "uncategorized_spending_override" => uncategorized_budgeted ? override_snapshot(uncategorized_override, uncategorized_budgeted) : {},
            "actual_income_entries" => actual_income.fetch(:source_snapshot),
            "actual_uncategorized_spending_entries" => uncategorized_actual.fetch(:source_snapshot)
          },
          risk_flags: Array(expected_income&.risk_flags) + Array(expected_income_override&.risk_flags) + Array(uncategorized_budgeted&.risk_flags) + actual_income.fetch(:risk_flags) + uncategorized_actual.fetch(:risk_flags),
          categories: category_rows
        }
      end

      def source_budget_for(period)
        budget = Budget.where(family: family)
          .where("start_date <= ?", period.start_date)
          .order(start_date: :desc, id: :desc)
          .detect(&:initialized?)

        budget&.current_user = user
        budget
      end

      def categories_for(budget, period, overrides)
        budget_rows = budget ? budget_categories_for(budget, period, overrides) : []
        budget_category_ids = budget_rows.map { |row| row.fetch(:category_id) }
        override_rows = overrides
          .select { |override| override.override_type == "category_spending" && override.category_id.present? && budget_category_ids.exclude?(override.category_id) }
          .group_by(&:category_id)
          .map { |_category_id, category_overrides| override_only_category_row(category_overrides.last, period) }
          .sort_by { |row| [ row.fetch(:name).to_s, row.fetch(:category_id).to_s ] }

        budget_rows + override_rows + actual_category_rows_for(period, budget_category_ids + override_rows.map { |row| row.fetch(:category_id) })
      end

      def budget_categories_for(budget, period, overrides)
        budget.budget_categories.includes(:category).order(:category_id, :id).reject { |budget_category| budget_category.category.subcategory? }.map do |budget_category|
          category = budget_category.category
          budgeted = money_converter.convert(amount: budget_category[:budgeted_spending].to_d, currency: budget_category.currency, source: "budget_category:#{budget_category.id}:budgeted_spending")
          override = latest_override(overrides, "category_spending", category_id: category.id)
          converted_override = override ? converted_override_amount(override) : nil
          budgeted_amount = converted_override&.amount || budgeted.amount
          actual = period_actual_spending(budget_category, period)
          distribution = Forecast::CategoryDistributionBuilder.new(category: category, expected_amount: budgeted_amount).call

          {
            category_id: category.id,
            parent_category_id: category.parent_id,
            projection_key: category.id,
            source: converted_override ? "forecast_budget_override" : "budget_inheritance",
            name: category.name,
            currency: money_converter.currency,
            budgeted_spending: budgeted_amount,
            actual_spending: actual.fetch(:amount),
            projected_spending_low: distribution.low,
            projected_spending_expected: distribution.expected,
            projected_spending_high: distribution.high,
            distribution_source: distribution.source,
            inherits_parent_budget: budget_category.inherits_parent_budget?,
            source_snapshot: {
              "budget_id" => budget.id,
              "budget_start_date" => budget.start_date.iso8601,
              "budget_end_date" => budget.end_date.iso8601,
              "budget_category_id" => budget_category.id,
              "category_id" => category.id,
              "category_name" => category.name,
              "parent_category_id" => category.parent_id,
              "inherits_parent_budget" => budget_category.inherits_parent_budget?,
              "budgeted_spending" => money_converter.snapshot_for(budgeted),
              "forecast_budget_override" => converted_override ? override_snapshot(override, converted_override) : {},
              "actual_spending_entries" => actual.fetch(:source_snapshot),
              "distribution" => {
                "source" => distribution.source,
                "low" => distribution.low.to_s,
                "expected" => distribution.expected.to_s,
                "high" => distribution.high.to_s
              }
            },
            risk_flags: budgeted.risk_flags + Array(converted_override&.risk_flags) + actual.fetch(:risk_flags) + distribution.risk_flags
          }
        end
      end

      def override_only_category_row(override, period)
        category = override.category
        converted = converted_override_amount(override)
        actual = period_actual_spending_for_category(category, period)
        distribution = Forecast::CategoryDistributionBuilder.new(category: category, expected_amount: converted.amount).call

        {
          category_id: category.id,
          parent_category_id: category.parent_id,
          projection_key: category.id,
          source: "forecast_budget_override",
          name: category.name,
          currency: money_converter.currency,
          budgeted_spending: converted.amount,
          actual_spending: actual.fetch(:amount),
          projected_spending_low: distribution.low,
          projected_spending_expected: distribution.expected,
          projected_spending_high: distribution.high,
          distribution_source: distribution.source,
          inherits_parent_budget: false,
          source_snapshot: {
            "budget_id" => nil,
            "category_id" => category.id,
            "category_name" => category.name,
            "parent_category_id" => category.parent_id,
            "forecast_budget_override" => override_snapshot(override, converted),
            "actual_spending_entries" => actual.fetch(:source_snapshot),
            "distribution" => {
              "source" => distribution.source,
              "low" => distribution.low.to_s,
              "expected" => distribution.expected.to_s,
              "high" => distribution.high.to_s
            }
          },
          risk_flags: converted.risk_flags + actual.fetch(:risk_flags) + distribution.risk_flags
        }
      end

      def actual_category_rows_for(period, excluded_category_ids)
        actuals = grouped_actuals_for(period)
          .reject { |category_id, _actual| excluded_category_ids.include?(category_id) }
        categories_by_id = family.categories.where(id: actuals.keys).index_by(&:id)

        actuals
          .sort_by { |category_id, _actual| category = categories_by_id.fetch(category_id); [ category.name.to_s, category.id.to_s ] }
          .map do |category_id, actual|
            category = categories_by_id.fetch(category_id)

            {
              category_id: category.id,
              parent_category_id: category.parent_id,
              projection_key: category.id,
              source: "actual",
              name: category.name,
              currency: money_converter.currency,
              budgeted_spending: 0.to_d,
              actual_spending: actual.fetch(:amount),
              projected_spending_low: actual.fetch(:amount),
              projected_spending_expected: actual.fetch(:amount),
              projected_spending_high: actual.fetch(:amount),
              distribution_source: "actual_only",
              inherits_parent_budget: false,
              source_snapshot: {
                "budget_id" => nil,
                "category_id" => category.id,
                "category_name" => category.name,
                "parent_category_id" => category.parent_id,
                "actual_spending_entries" => actual.fetch(:source_snapshot),
                "reason" => "actual_category_without_budget_row"
              },
              risk_flags: actual.fetch(:risk_flags)
            }
          end
      end

      def grouped_actuals_for(period)
        return {} unless period.start_date <= Date.current && period.end_date >= Date.current

        actual_entries(period).select { |entry| entry.transaction.category_id.present? }.each_with_object({}) do |entry, hash|
          category = entry.transaction.category
          projection_category = category.parent || category
          converted = convert_entry_amount(entry, "budget_category_actual")
          hash[projection_category.id] ||= { amount: 0.to_d, risk_flags: [], source_snapshot: [] }
          hash[projection_category.id][:amount] += spending_entry?(entry) ? converted.amount : -converted.amount
          hash[projection_category.id][:risk_flags].concat(converted.risk_flags)
          hash[projection_category.id][:source_snapshot] << entry_snapshot(entry, converted)
        end.transform_values do |actual|
          actual.merge(amount: [ actual.fetch(:amount), 0.to_d ].max)
        end.select { |_category_id, actual| actual.fetch(:amount).positive? }
      end

      def period_actual_spending(budget_category, period)
        return { amount: 0.to_d, risk_flags: [], source_snapshot: [] } unless period.start_date <= Date.current && period.end_date >= Date.current

        amount = 0.to_d
        risk_flags = []
        source_snapshot = []

        entries_for_category(budget_category.category, period).each do |entry|
          converted = convert_entry_amount(entry, "budget_spending")
          amount += spending_entry?(entry) ? converted.amount : -converted.amount
          risk_flags.concat(converted.risk_flags)
          source_snapshot << entry_snapshot(entry, converted)
        end

        { amount: [ amount, 0.to_d ].max, risk_flags: risk_flags, source_snapshot: source_snapshot }
      end

      def period_actual_spending_for_category(category, period)
        return { amount: 0.to_d, risk_flags: [], source_snapshot: [] } unless period.start_date <= Date.current && period.end_date >= Date.current

        amount = 0.to_d
        risk_flags = []
        source_snapshot = []

        entries_for_category(category, period).each do |entry|
          converted = convert_entry_amount(entry, "forecast_budget_override_actual")
          amount += spending_entry?(entry) ? converted.amount : -converted.amount
          risk_flags.concat(converted.risk_flags)
          source_snapshot << entry_snapshot(entry, converted)
        end

        { amount: [ amount, 0.to_d ].max, risk_flags: risk_flags, source_snapshot: source_snapshot }
      end

      def budget_overrides_for(period)
        scenario_order = scenario_ids.each_with_index.to_h
        family.forecast_budget_overrides
          .where(status: "active", period_start_on: period.start_date, forecast_scenario_id: [ nil, *scenario_ids ])
          .includes(:category, :forecast_scenario)
          .to_a
          .select { |override| override_active_for_period?(override, period) }
          .sort_by { |override| [ override.forecast_scenario_id ? scenario_order.fetch(override.forecast_scenario_id, 0) + 1 : 0, override.updated_at || Time.at(0), override.override_type, override.category_id.to_s, override.id ] }
      end

      def override_active_for_period?(override, period)
        scenario = override.forecast_scenario
        return true if scenario.blank?
        return false if scenario.starts_on.present? && period.start_date < scenario.starts_on
        return false if scenario.ends_on.present? && period.end_date > scenario.ends_on

        true
      end

      def latest_override(overrides, override_type, category_id: nil)
        overrides.select do |override|
          override.override_type == override_type && (category_id.nil? || override.category_id == category_id)
        end.last
      end

      def converted_override_amount(override)
        money_converter.convert(
          amount: override.amount,
          currency: override.currency,
          source: "forecast_budget_override:#{override.id}:amount"
        )
      end

      def override_snapshot(override, converted)
        {
          "id" => override.id,
          "forecast_scenario_id" => override.forecast_scenario_id,
          "period_start_on" => override.period_start_on.iso8601,
          "override_type" => override.override_type,
          "category_id" => override.category_id,
          "note" => override.note,
          "source_metadata" => override.source_metadata,
          "money" => money_converter.snapshot_for(converted)
        }
      end

      def actual_income_for(period)
        return { amount: 0.to_d, risk_flags: [], source_snapshot: [] } unless period.start_date <= Date.current && period.end_date >= Date.current

        amount = 0.to_d
        risk_flags = []
        source_snapshot = []

        actual_entries(period).each do |entry|
          if actual_liability_payment?(entry)
            converted = convert_entry_amount(entry, "liability_payment")
            risk_flags.concat(converted.risk_flags)
            risk_flags << { "type" => "actual_liability_payment_excluded_from_income", "entry_id" => entry.id, "account_id" => entry.account_id }
            source_snapshot << entry_snapshot(entry, converted).merge("excluded_reason" => "liability_payment")
            next
          end

          next 0.to_d if spending_entry?(entry)
          next 0.to_d if category_refund_entry?(entry)

          converted = convert_entry_amount(entry, "budget_income")
          amount += converted.amount
          risk_flags.concat(converted.risk_flags)
          source_snapshot << entry_snapshot(entry, converted)
        end

        { amount: amount, risk_flags: risk_flags, source_snapshot: source_snapshot }
      end

      def uncategorized_actual_spending_for(period)
        return { amount: 0.to_d, risk_flags: [], source_snapshot: [] } unless period.start_date <= Date.current && period.end_date >= Date.current

        amount = 0.to_d
        risk_flags = []
        source_snapshot = []

        actual_entries(period).select { |entry| entry.transaction.category_id.blank? }.each do |entry|
          converted = convert_entry_amount(entry, "uncategorized_actual_spending")
          amount += spending_entry?(entry) ? converted.amount : -converted.amount
          risk_flags.concat(converted.risk_flags)
          source_snapshot << entry_snapshot(entry, converted)
        end

        { amount: [ amount, 0.to_d ].max, risk_flags: risk_flags, source_snapshot: source_snapshot }
      end

      def entries_for_category(category, period)
        category_ids = [ category.id, *family.categories.where(parent_id: category.id).pluck(:id) ]
        actual_entries(period).select { |entry| category_ids.include?(entry.transaction.category_id) }
      end

      def actual_entries(period)
        @actual_entries ||= {}
        scope = family.entries.visible.excluding_pending
          .where(date: period.start_date..[ period.end_date, Date.current ].min, excluded: false, account_id: included_account_scope.ids)
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
          .where.not(transactions: { kind: Transaction::BUDGET_EXCLUDED_KINDS })
          .where("transactions.investment_activity_label IS NULL OR transactions.investment_activity_label NOT IN (?)", Transaction::INTERNAL_MOVEMENT_LABELS)
          .order(:date, :account_id, :id)
          .includes(:entryable)
        tax_advantaged_ids = family.tax_advantaged_account_ids
        scope = scope.where.not(account_id: tax_advantaged_ids) if tax_advantaged_ids.present?

        @actual_entries[period.start_date] ||= scope.to_a.reject do |entry|
          actual_budget_excluded?(entry)
        end
      end

      def actual_budget_excluded?(entry)
        Transaction::BUDGET_EXCLUDED_KINDS.include?(effective_transaction_kind(entry)) ||
          internal_investment_movement?(entry.transaction)
      end

      def internal_investment_movement?(transaction)
        transaction&.investment_activity_label.in?(Transaction::INTERNAL_MOVEMENT_LABELS)
      end

      def convert_entry_amount(entry, source_suffix)
        money_converter.convert(
          amount: entry.amount.to_d.abs,
          currency: entry.currency,
          source: "actual_entry:#{entry.id}:#{source_suffix}",
          as_of: entry.date
        )
      end

      def spending_entry?(entry)
        effective_transaction_kind(entry).in?(%w[loan_payment investment_contribution]) || entry.amount.to_d >= 0
      end

      def effective_transaction_kind(entry)
        transfer = entry.transaction.transfer_as_outflow
        return "funds_movement" if transfer.blank? && entry.transaction.transfer_as_inflow.present?
        return entry.transaction.kind if transfer.blank?

        source_account = transfer.from_account || entry.account
        destination_account = transfer.to_account
        return "loan_payment" if destination_account&.loan?
        return "cc_payment" if destination_account&.liability?
        return "investment_contribution" if investment_like?(destination_account) && !investment_like?(source_account)

        "funds_movement"
      end

      def investment_like?(account)
        account.present? && (account.investment? || account.crypto?)
      end

      def category_refund_entry?(entry)
        entry.amount.to_d.negative? &&
          entry.transaction.category.present? &&
          !income_category?(entry.transaction.category)
      end

      def income_category?(category)
        income_category_names.include?(category.name)
      end

      def income_category_names
        @income_category_names ||= I18n.available_locales.map { |locale| I18n.t("models.category.defaults.income", locale: locale) }.uniq
      end

      def actual_liability_payment?(entry)
        entry.account&.liability? && entry.amount.to_d.negative?
      end

      def entry_snapshot(entry, converted)
        {
          "id" => entry.id,
          "date" => entry.date&.iso8601,
          "name" => entry.name,
          "account_id" => entry.account_id,
          "category" => category_snapshot(entry.transaction.category),
          "transaction_kind" => entry.transaction.kind,
          "effective_transaction_kind" => effective_transaction_kind(entry),
          "signed_entry_amount" => entry.amount.to_s,
          "money" => money_converter.snapshot_for(converted)
        }
      end

      def category_snapshot(category)
        return nil if category.blank?

        {
          "id" => category.id,
          "name" => category.name,
          "parent_id" => category.parent_id,
          "parent_name" => category.parent&.name
        }
      end
  end
end
