# frozen_string_literal: true

module Forecasts
  # Plan-workspace assumption editing. Family-scoped through Current.family on
  # every query — an id from another family is a 404, never a 403 leak.
  class AssumptionsController < ApplicationController
    before_action :set_assumption

    def edit
      @form_partial = "forecasts/assumptions/form_#{@assumption.kind}"
    end

    private
      def set_assumption
        @assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
        head :not_found if @assumption.nil?
        @plan = @assumption&.forecast_plan
      end
  end
end
