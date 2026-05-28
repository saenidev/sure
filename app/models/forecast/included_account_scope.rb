module Forecast
  class IncludedAccountScope
    def initialize(family:, user:)
      @family = family
      @user = user
    end

    def relation
      family.accounts.visible.included_in_finances_for(user).order(:accountable_type, :name, :id)
    end

    def ids
      @ids ||= relation.reorder(nil).select(:id)
    end

    def id_values
      @id_values ||= relation.reorder(nil).pluck(:id)
    end

    private
      attr_reader :family, :user
  end
end
