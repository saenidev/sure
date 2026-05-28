module Forecast
  class PeriodBuilder
    PeriodWindow = Data.define(:index, :start_date, :end_date, :precision)
    Result = Data.define(:days, :months)

    def initialize(family:, start_on:, months: 36, daily_days: 90)
      @family = family
      @start_on = start_on
      @months = months
      @daily_days = daily_days
    end

    def call
      Result.new(
        days: (0...daily_days).map { |offset| start_on + offset.days },
        months: month_windows
      )
    end

    private
      attr_reader :family, :start_on, :months, :daily_days

      def month_windows
        first_start = family.uses_custom_month_start? ? family.custom_month_start_for(start_on) : start_on.beginning_of_month
        daily_until = start_on + (daily_days - 1).days

        (0...months).map do |index|
          period_start = first_start + index.months
          period_end = family.uses_custom_month_start? ? family.custom_month_end_for(period_start) : period_start.end_of_month
          precision = if period_start >= start_on && period_end <= daily_until
            "daily_backed"
          elsif index < 12
            "monthly"
          else
            "long_range"
          end
          PeriodWindow.new(index: index, start_date: period_start, end_date: period_end, precision: precision)
        end
      end
  end
end
