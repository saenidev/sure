# frozen_string_literal: true

# Forecast V2 release control (slice C1).
#
# WHY a feature check and not a separate mounted route:
#
#   The spec ("V1 Coexistence" + "Feature Flags And Release Control" + the Stage C
#   note) calls for V2 to ship behind explicit release controls AT the canonical
#   `/forecast` URL so we can flip families/users between V1 and V2 without moving
#   the route, breaking deep links, or shipping a second nav entry. A separate
#   mount (e.g. `/forecast_v2`) would fork bookmarks/nav and make cutover a URL
#   migration instead of a flag flip. So `ForecastsController#show` keeps ONE route
#   and branches on this predicate: flag off -> the untouched V1
#   `Forecast::Workspace` path; flag on -> the V2 (Inertia) path (built in C2+).
#
# Layered controls, matching the spec's recommended release controls. V2 is
# enabled for a request when the global switch is on AND the request's family
# OR user has been opted in. Disabling any layer returns that family/user to V1
# WITHOUT deleting any V2 plan data (pre-cutover rollback rule).
#
#   - Global switch:   FORECAST_V2_ENABLED env (default OFF). Hard kill-switch /
#                      org-wide rollback. When off, everyone gets V1.
#   - Family-level:    family id is in the FORECAST_V2_FAMILY_IDS allowlist
#                      ("V2 default for selected users/families"). Stored as
#                      config, not a new column, so this gate ships without a
#                      schema change; a richer per-family toggle can replace the
#                      allowlist later without touching the controller branch.
#   - User/admin preview: user.preferences["forecast_v2_preview"] == true
#                      (mirrors the existing preview_features_enabled pattern; the
#                      users table already has a preferences jsonb column).
#
# The predicate is a pure function of config + the passed family/user (no global
# Current.* reads, no Date.current, no DB writes) so it is trivially testable and
# the controller stays skinny. It never reads or mutates any V1 or V2 record.
Rails.application.configure do
  config.x.forecast_v2.tap do |forecast_v2|
    # Org-wide kill-switch. Off by default — V2 stays dark until explicitly turned
    # on, and flipping this back off is the pre-cutover global rollback.
    forecast_v2.enabled =
      ActiveModel::Type::Boolean.new.cast(
        ENV.fetch("FORECAST_V2_ENABLED", "false")
      )

    # Allowlist of family IDs that get V2 ("selected families" rollout stage).
    # Comma-separated env; blank by default. Parsed to a frozen Set of strings so
    # the predicate compares stringified ids without per-request allocation.
    forecast_v2.family_ids =
      ENV.fetch("FORECAST_V2_FAMILY_IDS", "")
        .split(",")
        .map { |id| id.strip }
        .reject(&:blank?)
        .to_set
        .freeze
  end
end

module Forecasts
  # Decides whether a given request should render the Forecast V2 surface at
  # `/forecast`. Pure predicate (no Current.*, no Date.current, no I/O) so the
  # controller branch is a one-liner and the test can drive every layer directly.
  module V2Flag
    module_function

    # @param family [Family, nil] the request family (Current.family)
    # @param user   [User, nil]   the request user (Current.user)
    # @return [Boolean] true when the V2 path should render
    def enabled_for?(family:, user: nil)
      return false unless globally_enabled?

      family_enabled?(family) || user_preview_enabled?(user)
    end

    # Org-wide switch. When false, NOBODY gets V2 (global rollback).
    def globally_enabled?
      Rails.configuration.x.forecast_v2.enabled == true
    end

    def family_enabled?(family)
      return false if family.nil?

      Rails.configuration.x.forecast_v2.family_ids.include?(family.id.to_s)
    end

    def user_preview_enabled?(user)
      user&.preferences&.dig("forecast_v2_preview") == true
    end
  end
end
