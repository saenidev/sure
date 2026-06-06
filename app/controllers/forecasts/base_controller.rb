# frozen_string_literal: true

module Forecasts
  # Shared base for the pluralized `Forecasts::` (V2) controller namespace. Every
  # later V2 slice that owns its own route (selected-period JSON in C5, the salary
  # editor drawer in C7, the salary save endpoint in C8) hangs off this base so
  # that:
  #
  #   - all reads/writes are scoped through `Current.family` (lookups go through
  #     the family association, so a cross-family id 404s instead of being
  #     trusted), and
  #   - the load-or-create plan + ensure-current-cache + first-viewport prop
  #     assembly is implemented ONCE (the Forecasts::WorkspaceLoading concern) and
  #     reused by both this base and the canonical `ForecastsController#show` V2
  #     branch.
  #
  # Deliberately separate from the V1 `Forecast::BaseController` (singular) so the
  # V1 service surface stays untouched (spec "V1 Coexistence": V1 classes are not
  # extended to support V2 behavior).
  class BaseController < ApplicationController
    include Forecasts::WorkspaceLoading
  end
end
