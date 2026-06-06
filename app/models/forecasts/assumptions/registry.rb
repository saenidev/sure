# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Forecast V2 Assumption Type Registry — the ONE server-side catalog that
    # every assumption kind must be registered in before it can be saved,
    # rendered, or expanded (spec "Assumption Type Registry Contract").
    #
    # Before this registry existed, per-kind dispatch was duplicated across the
    # engine (EXPANDERS), the assumptions controller (FORM_FOR_KIND), and the
    # assumption-group read model (ICON_FOR_KIND / KIND_ORDER). Each list was an
    # independent place a new kind could be half-wired or a stored kind silently
    # ignored. The registry replaces those scattered constants with a single
    # source of truth: every consumer resolves a kind THROUGH the registry, and an
    # unknown stored kind is a known, blocking condition rather than a silent
    # "no flows / default icon" fallthrough.
    #
    # It is a pure, deterministic lookup: no ActiveRecord, no Current.*, no
    # Date.current, no I/O. The MVP ships salary + living_expense; later kinds add
    # one entry here (plus their params/form/expander/locale) and every consumer
    # picks them up automatically.
    module Registry
      module_function

      UnknownKindError = Class.new(ArgumentError)

      # One immutable entry per kind. `order` fixes the rail group display order
      # (lower first); `icon` is rendered via the `icon` helper (never lucide
      # directly); `locale_scope` roots the kind's labels/sections/messages.
      Entry = Data.define(
        :kind, :order, :params_class, :form_class, :expander, :icon, :locale_scope
      )

      # The canonical kind catalog. Order is the rail group display order. Adding
      # a kind here is the single edit that wires it into the engine, the editor
      # save path, and the read-model rail at once.
      ENTRIES = [
        Entry.new(
          kind: "salary",
          order: 0,
          params_class: Forecasts::Assumptions::SalaryParams,
          form_class: Forecasts::Assumptions::SalaryForm,
          expander: Forecasts::Projection::Expanders::Salary,
          icon: "briefcase",
          locale_scope: "forecasts.assumptions.salary"
        ),
        Entry.new(
          kind: "living_expense",
          order: 1,
          params_class: Forecasts::Assumptions::LivingExpenseParams,
          form_class: Forecasts::Assumptions::LivingExpenseForm,
          expander: Forecasts::Projection::Expanders::LivingExpense,
          icon: "shopping-cart",
          locale_scope: "forecasts.assumptions.living_expense"
        )
      ].freeze

      BY_KIND = ENTRIES.index_by(&:kind).freeze

      # Default rail icon for a registered kind that omits one (none today). A
      # kind that is NOT registered never reaches this — it is a blocking issue.
      DEFAULT_ICON = "circle"

      # The full ordered kind list (rail group order). Replaces the read model's
      # standalone KIND_ORDER constant.
      def kinds
        ENTRIES.map(&:kind)
      end

      # True when `kind` is registered and may be saved/rendered/expanded.
      def registered?(kind)
        BY_KIND.key?(kind.to_s)
      end

      # The entry for `kind`, or nil when the kind is unknown. Consumers that must
      # tolerate an unknown stored kind (read models, the engine guard) use this;
      # consumers that require a known kind use `entry!`.
      def entry(kind)
        BY_KIND[kind.to_s]
      end

      # The entry for `kind`, raising UnknownKindError when unknown. Use at call
      # sites that have already proven the kind is supported (or want a loud
      # failure rather than a silent skip).
      def entry!(kind)
        entry(kind) || raise(UnknownKindError, "Unknown assumption kind #{kind.inspect}")
      end

      # --- Facet resolvers (single source of truth per consumer) -------------

      # Expander class for the engine pipeline, or nil for an unknown kind (the
      # engine maps nil to a blocking `unknown_assumption_kind` plan issue and
      # contributes no flows).
      def expander_for(kind)
        entry(kind)&.expander
      end

      # Typed form object for the create/edit endpoints, or nil for an unknown
      # kind (the controller returns 422 for an unknown kind).
      def form_class_for(kind)
        entry(kind)&.form_class
      end

      # Rail icon for a kind. Registered kinds carry their own; an unknown kind
      # (which the read model still renders defensively) falls back to the
      # neutral default.
      def icon_for(kind)
        entry(kind)&.icon || DEFAULT_ICON
      end

      # Localization scope rooting the kind's labels, sections, validation
      # messages, issue summaries, and action labels.
      def locale_scope_for(kind)
        entry(kind)&.locale_scope
      end

      # Stable display order index for a kind, used to order the rail groups.
      # Unknown kinds sort after every known kind (and then by kind name) so a
      # stray stored kind still renders deterministically at the end.
      def order_for(kind)
        entry(kind)&.order || (ENTRIES.length + 1)
      end
    end
  end
end
