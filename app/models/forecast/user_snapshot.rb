module Forecast
  module UserSnapshot
    extend ActiveSupport::Concern

    included do
      before_validation :snapshot_forecast_user
    end

    private
      def snapshot_forecast_user
        return if user.blank?
        return if user_snapshot.present? && !will_save_change_to_user_id?

        self.user_snapshot = {
          "id" => user.id,
          "display_name" => user.display_name,
          "email" => user.email
        }
      end
  end
end
