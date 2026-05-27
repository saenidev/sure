module Debt
  class AccrualSchedule
    def initialize(profile:, as_of: Date.current)
      @profile = profile
      @as_of = as_of
    end

    def due?
      return false if profile.last_accrued_on.present? && profile.last_accrued_on >= period_end_on
      return false if period_start_on > period_end_on

      daily? || monthly_due?
    end

    def period_start_on
      [ profile.last_accrued_on&.next_day, profile.effective_start_on ].compact.max || period_end_on
    end

    def period_end_on
      monthly? ? latest_monthly_anchor_on_or_before_as_of : as_of
    end

    private
      attr_reader :profile, :as_of

      def daily?
        profile.accrual_cadence.blank? || profile.accrual_cadence == "daily"
      end

      def monthly?
        profile.accrual_cadence == "monthly"
      end

      def monthly_due?
        return false unless monthly?

        as_of >= period_end_on
      end

      def latest_monthly_anchor_on_or_before_as_of
        anchor = monthly_anchor_for(as_of)
        return anchor if anchor <= as_of

        monthly_anchor_for(as_of.prev_month)
      end

      def monthly_anchor_for(date)
        if profile.statement_closing_day.present?
          last_day = Date.new(date.year, date.month, -1).day
          Date.new(date.year, date.month, [ profile.statement_closing_day, last_day ].min)
        else
          Date.new(date.year, date.month, -1)
        end
      end
  end
end
