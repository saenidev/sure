# frozen_string_literal: true

module Forecasts
  class Derivation
    # Immutable value object describing what derivation WOULD set on an
    # assumption — the bridge payload between the read-only Derivation
    # component and its writers (DefaultPlanBuilder seeding, the resync accept
    # endpoint). Carries the COMPLETE editable params contract (built through
    # SalaryParams / LivingExpenseParams) so a persisted row is always saveable
    # by the drawer forms.
    #
    # status :ok          — a usable proposal (amount/params/provenance filled in)
    # status :source_gone — the existing assumption's linked source record no
    #                       longer exists or no longer qualifies; only `kind`
    #                       is meaningful.
    class Proposal
      STATUSES = %i[ok source_gone].freeze

      attr_reader :kind, :name, :amount, :currency, :params, :confidence,
                  :source_record, :source_refs, :status

      def self.source_gone(kind:)
        new(
          kind: kind, name: nil, amount: nil, currency: nil, params: {},
          confidence: nil, source_record: nil, source_refs: {},
          needs_review: false, status: :source_gone
        )
      end

      def initialize(kind:, name:, amount:, currency:, params:, confidence:,
                     source_record:, source_refs:, needs_review:, status: :ok)
        raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status)

        @kind = kind
        @name = name
        @amount = amount
        @currency = currency
        @params = params
        @confidence = confidence
        @source_record = source_record
        @source_refs = source_refs
        @needs_review = needs_review
        @status = status
        freeze
      end

      def needs_review?
        @needs_review
      end

      def ok?
        status == :ok
      end

      def source_gone?
        status == :source_gone
      end
    end
  end
end
