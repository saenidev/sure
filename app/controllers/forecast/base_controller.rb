module Forecast
  # Shared base for the additive `Forecast::` controller namespace. Every later
  # slice hangs off this so that all reads/writes are scoped through the current
  # family. Cross-family ids raise ActiveRecord::RecordNotFound (-> 404) because
  # lookups go through the family association rather than trusting params[:id].
  class BaseController < ApplicationController
    before_action :set_family

    private
      def set_family
        @family = Current.family
      end

      # Look up a forecast run group scoped to the current family. Eager-loads
      # the runs so callers rendering a group avoid N+1 queries.
      def find_run_group_scoped(id = params[:id])
        @family.forecast_run_groups.includes(:forecast_runs).find(id)
      end

      def set_run_group
        @run_group = find_run_group_scoped
      end
  end
end
