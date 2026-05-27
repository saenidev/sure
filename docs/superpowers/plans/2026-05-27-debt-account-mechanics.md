# Debt Account Mechanics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build persisted debt account mechanics for liability accounts without touching forecasting code.

**Architecture:** Add additive debt tables that annotate Sure's existing `Entry` and `Transaction` ledger instead of replacing it. Implement debt terms, rate periods, obligations, generated debt events, payment allocations, reconciliation, posting-run audit rows, and account-page review surfaces in phases. Keep automatic interest posting opt-in and idempotent.

**Tech Stack:** Rails 7.2, ActiveRecord, PostgreSQL JSONB, UUID foreign keys, Minitest, ERB, existing Sure account and transaction models.

---

## Spec Review

The spec is implementable, but it is intentionally broad. The primary risk is creating a parallel balance ledger. The plan avoids that by requiring every balance-changing debt event to link to a real `Entry` + `Transaction`, while debt tables store terms, obligations, explanations, allocations, reconciliation state, and audit metadata.

The migration should be additive and compatible:

- Keep existing `Loan` and `CreditCard` columns.
- Use string statuses/kinds with model validations, not database enums.
- Use nullable provider/backfill fields.
- Store provider-only data in `extra`.
- Default auto posting off.

## File Structure

Create:

- `db/migrate/20260527001000_create_debt_mechanics_tables.rb`: all additive debt tables and indexes.
- `app/models/debt_profile.rb`: account-level debt configuration and associations.
- `app/models/debt_rate_period.rb`: dated interest-rate periods.
- `app/models/debt_event.rb`: generated/provider-observed debt events linked to ledger entries.
- `app/models/debt_obligation.rb`: statement-like due dates and payment obligations.
- `app/models/debt_payment_allocation.rb`: principal/interest/fee split for one payment entry.
- `app/models/debt_reconciliation_match.rb`: accepted/dismissed matches between generated events and provider entries.
- `app/models/debt_posting_run.rb`: audit rows for service runs.
- `app/models/debt/account_terms.rb`: normalized read model for debt services.
- `app/models/debt/projection.rb`: deterministic payoff projection.
- `app/models/debt/account_projection.rb`: account-level projection wrapper.
- `app/models/debt/interest_accrual_service.rb`: posts or matches interest events.
- `app/models/debt/obligation_service.rb`: imports or generates obligations.
- `app/models/debt/payment_allocation_service.rb`: allocates payment entries.
- `app/models/debt/reconciliation_service.rb`: finds provider matches for generated events.
- `test/models/debt_profile_test.rb`
- `test/models/debt_rate_period_test.rb`
- `test/models/debt_event_test.rb`
- `test/models/debt_obligation_test.rb`
- `test/models/debt_payment_allocation_test.rb`
- `test/models/debt_reconciliation_match_test.rb`
- `test/models/debt_posting_run_test.rb`
- `test/models/debt/account_terms_test.rb`
- `test/models/debt/projection_test.rb`
- `test/models/debt/interest_accrual_service_test.rb`
- `test/models/debt/obligation_service_test.rb`
- `test/models/debt/payment_allocation_service_test.rb`
- `test/models/debt/reconciliation_service_test.rb`
- `app/views/accounts/show/_debt_mechanics.html.erb`

Modify:

- `app/models/account.rb`: add debt associations and helpers.
- `app/models/loan.rb`: expose debt default terms without changing stored columns.
- `app/models/credit_card.rb`: expose debt default terms without changing stored columns.
- `app/models/account/provider_import_adapter.rb`: keep current behavior, add narrow hook for provider debt metadata once services exist.
- `app/views/loans/tabs/_overview.html.erb`: render debt mechanics section.
- `app/views/credit_cards/tabs/_overview.html.erb`: create tab path and render debt mechanics section.
- `app/components/UI/account_page.rb`: give credit cards an overview tab.
- `config/locales/views/accounts/en.yml`: debt mechanics strings.
- `config/locales/views/loans/en.yml`: any loan overview labels needed.
- `config/locales/views/credit_cards/en.yml`: any credit-card overview labels needed.

Do not modify forecast files in this plan.

## Task 1: Add Debt Mechanics Schema

**Files:**

- Create: `db/migrate/20260527001000_create_debt_mechanics_tables.rb`
- Test: `bin/rails db:migrate`

- [ ] **Step 1: Add the migration**

Create `db/migrate/20260527001000_create_debt_mechanics_tables.rb`:

```ruby
class CreateDebtMechanicsTables < ActiveRecord::Migration[7.2]
  def change
    create_table :debt_profiles, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.string :status, null: false, default: "active"
      t.boolean :auto_accrual_enabled, null: false, default: false
      t.boolean :auto_payment_allocation_enabled, null: false, default: false
      t.string :rate_type
      t.string :accrual_cadence
      t.string :compounding_cadence
      t.decimal :minimum_payment_amount, precision: 19, scale: 4
      t.decimal :minimum_payment_percent, precision: 10, scale: 4
      t.integer :payment_due_day
      t.integer :statement_closing_day
      t.integer :grace_period_days
      t.date :effective_start_on
      t.date :effective_end_on
      t.date :last_accrued_on
      t.date :next_due_on
      t.string :source
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_profiles, :status
    add_index :debt_profiles, :next_due_on
    add_index :debt_profiles, :extra, using: :gin

    create_table :debt_rate_periods, id: :uuid do |t|
      t.references :debt_profile, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :rate_type, null: false
      t.decimal :annual_rate, precision: 10, scale: 4, null: false
      t.date :starts_on, null: false
      t.date :ends_on
      t.integer :priority, null: false, default: 0
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_rate_periods, [ :debt_profile_id, :starts_on ]
    add_index :debt_rate_periods, [ :debt_profile_id, :external_id ], unique: true, where: "external_id IS NOT NULL"
    add_index :debt_rate_periods, :extra, using: :gin

    create_table :debt_events, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :entry, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :event_type, null: false
      t.string :status, null: false
      t.date :event_date, null: false
      t.date :period_start_on
      t.date :period_end_on
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.string :idempotency_key
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_events, [ :account_id, :event_date ]
    add_index :debt_events, [ :account_id, :event_type, :status ]
    add_index :debt_events, [ :account_id, :idempotency_key ], unique: true, where: "idempotency_key IS NOT NULL"
    add_index :debt_events, [ :account_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_events, :extra, using: :gin

    create_table :debt_obligations, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.date :statement_on
      t.date :period_start_on
      t.date :period_end_on
      t.date :due_on, null: false
      t.string :status, null: false
      t.decimal :statement_balance_amount, precision: 19, scale: 4
      t.decimal :minimum_payment_amount, precision: 19, scale: 4
      t.decimal :principal_due_amount, precision: 19, scale: 4
      t.decimal :interest_due_amount, precision: 19, scale: 4
      t.decimal :fee_due_amount, precision: 19, scale: 4
      t.decimal :paid_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_obligations, [ :account_id, :due_on ]
    add_index :debt_obligations, [ :account_id, :status ]
    add_index :debt_obligations, [ :account_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_obligations, :extra, using: :gin

    create_table :debt_payment_allocations, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: { unique: true }
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :debt_obligation, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :allocation_method, null: false
      t.string :status, null: false
      t.decimal :principal_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :interest_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :fee_amount, precision: 19, scale: 4, null: false, default: 0
      t.decimal :unapplied_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_payment_allocations, [ :account_id, :status ]
    add_index :debt_payment_allocations, [ :account_id, :source, :external_id ], unique: true, where: "source IS NOT NULL AND external_id IS NOT NULL"
    add_index :debt_payment_allocations, :extra, using: :gin

    create_table :debt_reconciliation_matches, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_event, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :match_type, null: false
      t.string :confidence, null: false
      t.string :status, null: false
      t.date :matched_on
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_reconciliation_matches, [ :account_id, :status ]
    add_index :debt_reconciliation_matches, [ :debt_event_id, :entry_id ], unique: true
    add_index :debt_reconciliation_matches, :extra, using: :gin

    create_table :debt_posting_runs, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :debt_profile, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :run_type, null: false
      t.date :period_start_on
      t.date :period_end_on
      t.string :status, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_class
      t.text :error_message
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :debt_posting_runs, [ :account_id, :run_type, :period_start_on, :period_end_on ], name: "index_debt_posting_runs_on_account_run_type_period"
    add_index :debt_posting_runs, :extra, using: :gin
  end
end
```

- [ ] **Step 2: Run migration**

Run:

```bash
bin/rails db:migrate
```

Expected: migration succeeds and `db/schema.rb` includes all seven debt tables.

- [ ] **Step 3: Commit schema**

```bash
git add db/migrate/20260527001000_create_debt_mechanics_tables.rb db/schema.rb
git commit -m "Add debt mechanics tables"
```

## Task 2: Add Debt Models And Validations

**Files:**

- Create: `app/models/debt_profile.rb`
- Create: `app/models/debt_rate_period.rb`
- Create: `app/models/debt_event.rb`
- Create: `app/models/debt_obligation.rb`
- Create: `app/models/debt_payment_allocation.rb`
- Create: `app/models/debt_reconciliation_match.rb`
- Create: `app/models/debt_posting_run.rb`
- Modify: `app/models/account.rb`
- Test: `test/models/debt_profile_test.rb`
- Test: `test/models/debt_rate_period_test.rb`
- Test: `test/models/debt_event_test.rb`
- Test: `test/models/debt_obligation_test.rb`
- Test: `test/models/debt_payment_allocation_test.rb`
- Test: `test/models/debt_reconciliation_match_test.rb`
- Test: `test/models/debt_posting_run_test.rb`

- [ ] **Step 1: Write failing association and validation tests**

Create `test/models/debt_profile_test.rb`:

```ruby
require "test_helper"

class DebtProfileTest < ActiveSupport::TestCase
  setup do
    @loan_account = accounts(:loan)
    @asset_account = accounts(:depository)
  end

  test "accepts liability account" do
    profile = DebtProfile.new(account: @loan_account, status: "active")

    assert profile.valid?
  end

  test "rejects asset account" do
    profile = DebtProfile.new(account: @asset_account, status: "active")

    assert_not profile.valid?
    assert_includes profile.errors[:account], "must be a liability account"
  end

  test "validates day fields" do
    profile = DebtProfile.new(
      account: @loan_account,
      payment_due_day: 32,
      statement_closing_day: 0
    )

    assert_not profile.valid?
    assert_includes profile.errors[:payment_due_day], "must be between 1 and 31"
    assert_includes profile.errors[:statement_closing_day], "must be between 1 and 31"
  end

  test "effective end cannot be before start" do
    profile = DebtProfile.new(
      account: @loan_account,
      effective_start_on: Date.new(2026, 2, 1),
      effective_end_on: Date.new(2026, 1, 1)
    )

    assert_not profile.valid?
    assert_includes profile.errors[:effective_end_on], "must be on or after effective_start_on"
  end
end
```

Create `test/models/debt_rate_period_test.rb`:

```ruby
require "test_helper"

class DebtRatePeriodTest < ActiveSupport::TestCase
  setup do
    @profile = DebtProfile.create!(account: accounts(:loan))
  end

  test "rejects overlapping periods for same profile and priority" do
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 6.25,
      starts_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30),
      priority: 0
    )

    overlap = DebtRatePeriod.new(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 7.25,
      starts_on: Date.new(2026, 6, 1),
      priority: 0
    )

    assert_not overlap.valid?
    assert_includes overlap.errors[:starts_on], "overlaps an existing rate period"
  end

  test "allows overlapping periods at different priorities" do
    DebtRatePeriod.create!(
      debt_profile: @profile,
      rate_type: "fixed",
      annual_rate: 6.25,
      starts_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 6, 30),
      priority: 0
    )

    promotional = DebtRatePeriod.new(
      debt_profile: @profile,
      rate_type: "promotional",
      annual_rate: 0,
      starts_on: Date.new(2026, 3, 1),
      ends_on: Date.new(2026, 4, 30),
      priority: 10
    )

    assert promotional.valid?
  end
end
```

Create `test/models/debt_event_test.rb`:

```ruby
require "test_helper"

class DebtEventTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
  end

  test "posted interest event requires a ledger entry" do
    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "posted",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert_not event.valid?
    assert_includes event.errors[:entry], "must be present for posted balance-changing events"
  end

  test "pending interest event can exist without entry" do
    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert event.valid?
  end

  test "linked entry must belong to event account" do
    other_entry = accounts(:credit_card).entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    event = DebtEvent.new(
      account: @account,
      debt_profile: @profile,
      entry: other_entry,
      event_type: "interest_accrual",
      status: "posted",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )

    assert_not event.valid?
    assert_includes event.errors[:entry], "must belong to account"
  end
end
```

Create `test/models/debt_obligation_test.rb`:

```ruby
require "test_helper"

class DebtObligationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:credit_card)
    @profile = DebtProfile.create!(account: @account)
  end

  test "validates non-negative amounts" do
    obligation = DebtObligation.new(
      account: @account,
      debt_profile: @profile,
      due_on: Date.new(2026, 2, 15),
      status: "open",
      minimum_payment_amount: -1,
      paid_amount: -1,
      currency: "USD"
    )

    assert_not obligation.valid?
    assert_includes obligation.errors[:minimum_payment_amount], "must be greater than or equal to 0"
    assert_includes obligation.errors[:paid_amount], "must be greater than or equal to 0"
  end
end
```

Create `test/models/debt_payment_allocation_test.rb`:

```ruby
require "test_helper"

class DebtPaymentAllocationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @entry = @account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Loan payment",
      amount: -500,
      currency: "USD",
      entryable: Transaction.new(kind: "loan_payment")
    )
  end

  test "validates allocation components match payment magnitude" do
    allocation = DebtPaymentAllocation.new(
      account: @account,
      entry: @entry,
      debt_profile: @profile,
      allocation_method: "automatic",
      status: "allocated",
      principal_amount: 300,
      interest_amount: 100,
      fee_amount: 0,
      unapplied_amount: 0,
      currency: "USD"
    )

    assert_not allocation.valid?
    assert_includes allocation.errors[:base], "allocation components must equal payment magnitude"
  end

  test "allows imbalanced allocation when review is required" do
    allocation = DebtPaymentAllocation.new(
      account: @account,
      entry: @entry,
      debt_profile: @profile,
      allocation_method: "automatic",
      status: "needs_review",
      principal_amount: 300,
      interest_amount: 100,
      currency: "USD"
    )

    assert allocation.valid?
  end

  test "rejects asset account" do
    asset_account = accounts(:depository)
    asset_entry = asset_account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Outgoing transfer",
      amount: -500,
      currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )

    allocation = DebtPaymentAllocation.new(
      account: asset_account,
      entry: asset_entry,
      allocation_method: "automatic",
      status: "allocated",
      principal_amount: 500,
      currency: "USD"
    )

    assert_not allocation.valid?
    assert_includes allocation.errors[:account], "must be a liability account"
  end
end
```

Create `test/models/debt_reconciliation_match_test.rb`:

```ruby
require "test_helper"

class DebtReconciliationMatchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @entry = @account.entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    @event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )
  end

  test "accepting match marks event matched" do
    match = DebtReconciliationMatch.create!(
      account: @account,
      debt_event: @event,
      entry: @entry,
      match_type: "exact",
      confidence: "high",
      status: "accepted",
      matched_on: Date.current
    )

    assert_equal "accepted", match.status
    assert_equal "matched", @event.reload.status
  end
end
```

Create `test/models/debt_posting_run_test.rb`:

```ruby
require "test_helper"

class DebtPostingRunTest < ActiveSupport::TestCase
  test "accepts a liability account posting run" do
    account = accounts(:loan)
    profile = DebtProfile.create!(account: account)

    run = DebtPostingRun.new(
      account: account,
      debt_profile: profile,
      run_type: "interest_accrual",
      status: "started"
    )

    assert run.valid?
  end

  test "rejects asset account posting run" do
    run = DebtPostingRun.new(
      account: accounts(:depository),
      run_type: "interest_accrual",
      status: "started"
    )

    assert_not run.valid?
    assert_includes run.errors[:account], "must be a liability account"
  end
end
```

- [ ] **Step 2: Run tests to verify missing constants**

Run:

```bash
bin/rails test test/models/debt_profile_test.rb test/models/debt_rate_period_test.rb test/models/debt_event_test.rb test/models/debt_obligation_test.rb test/models/debt_payment_allocation_test.rb test/models/debt_reconciliation_match_test.rb test/models/debt_posting_run_test.rb
```

Expected: tests fail with missing constants such as `uninitialized constant DebtProfile`.

- [ ] **Step 3: Add model implementations**

Create `app/models/debt_profile.rb`:

```ruby
class DebtProfile < ApplicationRecord
  STATUSES = %w[active disabled archived].freeze
  RATE_TYPES = %w[fixed variable adjustable promotional].freeze
  CADENCES = %w[daily monthly].freeze

  belongs_to :account

  has_many :debt_rate_periods, dependent: :destroy
  has_many :debt_events, dependent: :nullify
  has_many :debt_obligations, dependent: :nullify
  has_many :debt_payment_allocations, dependent: :nullify
  has_many :debt_posting_runs, dependent: :nullify

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :rate_type, inclusion: { in: RATE_TYPES }, allow_blank: true
  validates :accrual_cadence, inclusion: { in: CADENCES }, allow_blank: true
  validates :compounding_cadence, inclusion: { in: CADENCES }, allow_blank: true
  validates :minimum_payment_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :minimum_payment_percent, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :grace_period_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_must_be_liability
  validate :day_fields_in_range
  validate :effective_dates_ordered

  def active?
    status == "active"
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def day_fields_in_range
      %i[payment_due_day statement_closing_day].each do |field|
        value = public_send(field)
        next if value.blank?
        next if value.between?(1, 31)

        errors.add(field, "must be between 1 and 31")
      end
    end

    def effective_dates_ordered
      return if effective_start_on.blank? || effective_end_on.blank?
      return if effective_end_on >= effective_start_on

      errors.add(:effective_end_on, "must be on or after effective_start_on")
    end
end
```

Create `app/models/debt_rate_period.rb`:

```ruby
class DebtRatePeriod < ApplicationRecord
  RATE_TYPES = DebtProfile::RATE_TYPES

  belongs_to :debt_profile

  validates :rate_type, presence: true, inclusion: { in: RATE_TYPES }
  validates :annual_rate, numericality: { greater_than_or_equal_to: 0 }
  validates :starts_on, presence: true
  validates :priority, numericality: { only_integer: true }
  validate :ends_on_not_before_starts_on
  validate :does_not_overlap_same_priority

  scope :for_date, ->(date) {
    where("starts_on <= ?", date)
      .where("ends_on IS NULL OR ends_on >= ?", date)
      .order(priority: :desc, starts_on: :desc)
  }

  private
    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank?
      return if ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def does_not_overlap_same_priority
      return if debt_profile_id.blank? || starts_on.blank?

      relation = self.class
        .where(debt_profile_id: debt_profile_id, priority: priority)
        .where.not(id: id)
        .where("starts_on <= ?", ends_on || Date.new(9999, 12, 31))
        .where("ends_on IS NULL OR ends_on >= ?", starts_on)

      errors.add(:starts_on, "overlaps an existing rate period") if relation.exists?
    end
end
```

Create `app/models/debt_event.rb`:

```ruby
class DebtEvent < ApplicationRecord
  EVENT_TYPES = %w[interest_accrual fee principal_adjustment rate_change manual_adjustment provider_observed].freeze
  STATUSES = %w[pending posted matched voided superseded].freeze
  BALANCE_CHANGING_TYPES = %w[interest_accrual fee principal_adjustment manual_adjustment].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true
  belongs_to :entry, optional: true

  has_many :debt_reconciliation_matches, dependent: :destroy

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :event_date, :currency, presence: true
  validates :amount, numericality: true
  validate :account_must_be_liability
  validate :entry_belongs_to_account
  validate :posted_balance_changing_events_require_entry

  def balance_changing?
    BALANCE_CHANGING_TYPES.include?(event_type)
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def entry_belongs_to_account
      return if entry.blank? || account.blank? || entry.account_id == account.id

      errors.add(:entry, "must belong to account")
    end

    def posted_balance_changing_events_require_entry
      return unless status == "posted" && balance_changing?
      return if entry.present?

      errors.add(:entry, "must be present for posted balance-changing events")
    end
end
```

Create `app/models/debt_obligation.rb`:

```ruby
class DebtObligation < ApplicationRecord
  STATUSES = %w[open partially_paid paid overdue waived superseded].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true
  has_many :debt_payment_allocations, dependent: :nullify

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :due_on, :currency, presence: true
  validates :statement_balance_amount, :minimum_payment_amount, :principal_due_amount,
            :interest_due_amount, :fee_due_amount, :paid_amount,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_must_be_liability
  validate :period_dates_ordered

  def amount_due
    minimum_payment_amount || statement_balance_amount || 0.to_d
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def period_dates_ordered
      return if period_start_on.blank? || period_end_on.blank?
      return if period_end_on >= period_start_on

      errors.add(:period_end_on, "must be on or after period_start_on")
    end
end
```

Create `app/models/debt_payment_allocation.rb`:

```ruby
class DebtPaymentAllocation < ApplicationRecord
  METHODS = %w[automatic provider manual].freeze
  STATUSES = %w[allocated estimated needs_review voided].freeze

  belongs_to :account
  belongs_to :entry
  belongs_to :debt_profile, optional: true
  belongs_to :debt_obligation, optional: true

  validates :allocation_method, presence: true, inclusion: { in: METHODS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :currency, presence: true
  validates :principal_amount, :interest_amount, :fee_amount, :unapplied_amount,
            numericality: { greater_than_or_equal_to: 0 }
  validate :account_must_be_liability
  validate :entry_belongs_to_account
  validate :entry_is_liability_payment
  validate :components_equal_payment_magnitude_unless_review

  def component_total
    principal_amount + interest_amount + fee_amount + unapplied_amount
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def entry_belongs_to_account
      return if entry.blank? || account.blank? || entry.account_id == account.id

      errors.add(:entry, "must belong to account")
    end

    def entry_is_liability_payment
      return if entry.blank?
      return if entry.amount.negative?

      errors.add(:entry, "must decrease liability balance")
    end

    def components_equal_payment_magnitude_unless_review
      return if status == "needs_review"
      return if entry.blank?
      return if component_total == entry.amount.abs

      errors.add(:base, "allocation components must equal payment magnitude")
    end
end
```

Create `app/models/debt_reconciliation_match.rb`:

```ruby
class DebtReconciliationMatch < ApplicationRecord
  MATCH_TYPES = %w[exact date_amount manual].freeze
  CONFIDENCES = %w[high medium low].freeze
  STATUSES = %w[accepted dismissed needs_review].freeze

  belongs_to :account
  belongs_to :debt_event
  belongs_to :entry

  after_save :mark_event_matched, if: :accepted?

  validates :match_type, presence: true, inclusion: { in: MATCH_TYPES }
  validates :confidence, presence: true, inclusion: { in: CONFIDENCES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :records_belong_to_account

  def accepted?
    status == "accepted"
  end

  private
    def records_belong_to_account
      errors.add(:debt_event, "must belong to account") if debt_event && debt_event.account_id != account_id
      errors.add(:entry, "must belong to account") if entry && entry.account_id != account_id
    end

    def mark_event_matched
      debt_event.update!(status: "matched")
    end
end
```

Create `app/models/debt_posting_run.rb`:

```ruby
class DebtPostingRun < ApplicationRecord
  RUN_TYPES = %w[interest_accrual payment_allocation obligation_generation reconciliation].freeze
  STATUSES = %w[started succeeded failed skipped].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true

  validates :run_type, presence: true, inclusion: { in: RUN_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :account_must_be_liability

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end
end
```

Modify `app/models/account.rb` near the existing associations:

```ruby
  has_one :debt_profile, dependent: :destroy
  has_many :debt_events, dependent: :destroy
  has_many :debt_obligations, dependent: :destroy
  has_many :debt_payment_allocations, dependent: :destroy
  has_many :debt_posting_runs, dependent: :destroy
```

Add helpers to `app/models/account.rb` near other instance helpers:

```ruby
  def debt_mechanics_supported?
    liability?
  end

  def debt_mechanics_enabled?
    debt_profile&.active? || false
  end
```

- [ ] **Step 4: Run model tests**

Run:

```bash
bin/rails test test/models/debt_profile_test.rb test/models/debt_rate_period_test.rb test/models/debt_event_test.rb test/models/debt_obligation_test.rb test/models/debt_payment_allocation_test.rb test/models/debt_reconciliation_match_test.rb test/models/debt_posting_run_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Commit models**

```bash
git add app/models/account.rb app/models/debt_profile.rb app/models/debt_rate_period.rb app/models/debt_event.rb app/models/debt_obligation.rb app/models/debt_payment_allocation.rb app/models/debt_reconciliation_match.rb app/models/debt_posting_run.rb test/models/debt_profile_test.rb test/models/debt_rate_period_test.rb test/models/debt_event_test.rb test/models/debt_obligation_test.rb test/models/debt_payment_allocation_test.rb test/models/debt_reconciliation_match_test.rb test/models/debt_posting_run_test.rb
git commit -m "Add debt mechanics models"
```

## Task 3: Add Debt Terms And Projection Services

**Files:**

- Create: `app/models/debt/account_terms.rb`
- Create: `app/models/debt/projection.rb`
- Create: `app/models/debt/account_projection.rb`
- Modify: `app/models/loan.rb`
- Modify: `app/models/credit_card.rb`
- Test: `test/models/debt/account_terms_test.rb`
- Test: `test/models/debt/projection_test.rb`

- [ ] **Step 1: Write failing tests**

Create `test/models/debt/account_terms_test.rb`:

```ruby
require "test_helper"

class Debt::AccountTermsTest < ActiveSupport::TestCase
  test "resolves fixed loan terms from existing loan fields" do
    account = accounts(:loan)
    terms = Debt::AccountTerms.new(account).call

    assert terms.projectable?
    assert_equal "fixed", terms.rate_type
    assert_equal account.loan.interest_rate.to_d, terms.annual_rate
    assert terms.monthly_payment.positive?
  end

  test "debt profile overrides loan payment and rate" do
    account = accounts(:loan)
    profile = DebtProfile.create!(
      account: account,
      rate_type: "fixed",
      minimum_payment_amount: 1_250
    )
    profile.debt_rate_periods.create!(
      rate_type: "fixed",
      annual_rate: 8.25,
      starts_on: Date.new(2026, 1, 1)
    )

    terms = Debt::AccountTerms.new(account, as_of: Date.new(2026, 2, 1)).call

    assert terms.projectable?
    assert_equal 8.25.to_d, terms.annual_rate
    assert_equal 1_250.to_d, terms.monthly_payment
  end

  test "credit card terms use apr and minimum payment" do
    account = accounts(:credit_card)
    terms = Debt::AccountTerms.new(account).call

    assert terms.projectable?
    assert_equal account.credit_card.apr.to_d, terms.annual_rate
    assert_equal account.credit_card.minimum_payment.to_d, terms.monthly_payment
  end

  test "other liability requires profile terms" do
    account = accounts(:other_liability)

    missing = Debt::AccountTerms.new(account).call

    assert_not missing.projectable?
    assert_includes missing.missing_fields, :annual_rate
    assert_includes missing.missing_fields, :monthly_payment

    profile = DebtProfile.create!(
      account: account,
      rate_type: "fixed",
      minimum_payment_amount: 50
    )
    profile.debt_rate_periods.create!(rate_type: "fixed", annual_rate: 5, starts_on: Date.current)

    present = Debt::AccountTerms.new(account).call

    assert present.projectable?
  end
end
```

Create `test/models/debt/projection_test.rb`:

```ruby
require "test_helper"

class Debt::ProjectionTest < ActiveSupport::TestCase
  test "projects monthly payoff rows" do
    result = Debt::Projection.new(
      opening_balance: 10_000.to_d,
      annual_rate: 12.to_d,
      monthly_payment: 500.to_d,
      start_on: Date.new(2026, 1, 1),
      months: 2
    ).call

    assert_equal 2, result.rows.size
    assert_equal 10_000.to_d, result.rows.first.opening_balance
    assert_equal 100.to_d, result.rows.first.accrued_interest
    assert_equal 500.to_d, result.rows.first.payment
    assert_equal 9_600.to_d, result.rows.first.closing_balance
  end

  test "caps final payment at remaining balance plus interest" do
    result = Debt::Projection.new(
      opening_balance: 300.to_d,
      annual_rate: 0.to_d,
      monthly_payment: 500.to_d,
      start_on: Date.new(2026, 1, 1),
      months: 12
    ).call

    assert_equal 1, result.rows.size
    assert_equal 300.to_d, result.rows.first.payment
    assert_equal 0.to_d, result.rows.first.closing_balance
    assert_not result.truncated?
  end

  test "marks projection truncated when payment does not amortize" do
    result = Debt::Projection.new(
      opening_balance: 10_000.to_d,
      annual_rate: 24.to_d,
      monthly_payment: 50.to_d,
      start_on: Date.new(2026, 1, 1),
      months: 12
    ).call

    assert result.truncated?
    assert_nil result.payoff_on
  end
end
```

- [ ] **Step 2: Run tests to verify missing services**

Run:

```bash
bin/rails test test/models/debt/account_terms_test.rb test/models/debt/projection_test.rb
```

Expected: tests fail with missing `Debt::AccountTerms` and `Debt::Projection`.

- [ ] **Step 3: Add debt term defaults to accountables**

Modify `app/models/loan.rb`:

```ruby
  def debt_default_rate_type
    rate_type
  end

  def debt_default_annual_rate
    interest_rate
  end

  def debt_default_monthly_payment
    monthly_payment&.amount
  end
```

Modify `app/models/credit_card.rb`:

```ruby
  def debt_default_rate_type
    "variable"
  end

  def debt_default_annual_rate
    apr
  end

  def debt_default_monthly_payment
    minimum_payment
  end
```

- [ ] **Step 4: Add terms resolver and projection services**

Create `app/models/debt/account_terms.rb`:

```ruby
module Debt
  class AccountTerms
    Result = Data.define(
      :account,
      :projectable,
      :missing_fields,
      :rate_type,
      :annual_rate,
      :monthly_payment,
      :opening_balance,
      :currency,
      :source
    ) do
      def projectable?
        projectable
      end
    end

    def initialize(account, as_of: Date.current)
      @account = account
      @as_of = as_of
    end

    def call
      missing = []
      missing << :account unless account&.liability?
      missing << :annual_rate if annual_rate.blank?
      missing << :monthly_payment if monthly_payment.blank? || monthly_payment.to_d <= 0
      missing << :opening_balance if opening_balance.blank?

      Result.new(
        account: account,
        projectable: missing.empty?,
        missing_fields: missing,
        rate_type: resolved_rate_type,
        annual_rate: annual_rate&.to_d,
        monthly_payment: monthly_payment&.to_d,
        opening_balance: opening_balance&.to_d,
        currency: account&.currency,
        source: source
      )
    end

    private
      attr_reader :account, :as_of

      def profile
        @profile ||= account&.debt_profile
      end

      def active_rate_period
        @active_rate_period ||= profile&.debt_rate_periods&.for_date(as_of)&.first
      end

      def resolved_rate_type
        active_rate_period&.rate_type || profile&.rate_type || accountable_default(:debt_default_rate_type)
      end

      def annual_rate
        active_rate_period&.annual_rate || accountable_default(:debt_default_annual_rate)
      end

      def monthly_payment
        profile&.minimum_payment_amount || accountable_default(:debt_default_monthly_payment)
      end

      def opening_balance
        account&.balance
      end

      def source
        return "debt_profile" if profile.present?
        return account.accountable_type.underscore if account&.accountable.present?

        nil
      end

      def accountable_default(method_name)
        return nil unless account&.accountable&.respond_to?(method_name)

        account.accountable.public_send(method_name)
      end
  end
end
```

Create `app/models/debt/projection.rb`:

```ruby
module Debt
  class Projection
    Row = Data.define(:period_start, :period_end, :opening_balance, :accrued_interest, :payment, :closing_balance)
    Result = Data.define(:rows, :total_interest, :payoff_on, :truncated) do
      def truncated?
        truncated
      end
    end

    def initialize(opening_balance:, annual_rate:, monthly_payment:, start_on:, months: 360)
      @opening_balance = opening_balance.to_d
      @annual_rate = annual_rate.to_d
      @monthly_payment = monthly_payment.to_d
      @start_on = start_on.to_date.beginning_of_month
      @months = months.to_i
    end

    def call
      balance = opening_balance
      total_interest = 0.to_d
      payoff_on = nil
      rows = []

      months.times do |offset|
        period_start = start_on + offset.months
        period_end = period_start.end_of_month
        interest = (balance * monthly_rate).round(4)
        total_due = balance + interest
        payment = [ monthly_payment, total_due ].min
        closing = [ total_due - payment, 0.to_d ].max
        row = Row.new(
          period_start: period_start,
          period_end: period_end,
          opening_balance: balance,
          accrued_interest: interest,
          payment: payment,
          closing_balance: closing
        )

        total_interest += interest
        balance = closing
        rows << row

        if closing.zero?
          payoff_on = period_end
          break
        end
      end

      Result.new(rows: rows, total_interest: total_interest, payoff_on: payoff_on, truncated: payoff_on.nil?)
    end

    private
      attr_reader :opening_balance, :annual_rate, :monthly_payment, :start_on, :months

      def monthly_rate
        annual_rate / 100 / 12
      end
  end
end
```

Create `app/models/debt/account_projection.rb`:

```ruby
module Debt
  class AccountProjection
    def initialize(account, as_of: Date.current, months: 360)
      @account = account
      @as_of = as_of
      @months = months
    end

    def call
      terms = AccountTerms.new(account, as_of: as_of).call
      return terms unless terms.projectable?

      Projection.new(
        opening_balance: terms.opening_balance,
        annual_rate: terms.annual_rate,
        monthly_payment: terms.monthly_payment,
        start_on: as_of,
        months: months
      ).call
    end

    private
      attr_reader :account, :as_of, :months
  end
end
```

- [ ] **Step 5: Run tests**

Run:

```bash
bin/rails test test/models/debt/account_terms_test.rb test/models/debt/projection_test.rb
```

Expected: all tests pass.

- [ ] **Step 6: Commit debt terms and projections**

```bash
git add app/models/loan.rb app/models/credit_card.rb app/models/debt/account_terms.rb app/models/debt/projection.rb app/models/debt/account_projection.rb test/models/debt/account_terms_test.rb test/models/debt/projection_test.rb
git commit -m "Add debt terms and payoff projection services"
```

## Task 4: Add Interest Accrual And Reconciliation Services

**Files:**

- Create: `app/models/debt/reconciliation_service.rb`
- Create: `app/models/debt/interest_accrual_service.rb`
- Test: `test/models/debt/reconciliation_service_test.rb`
- Test: `test/models/debt/interest_accrual_service_test.rb`

- [ ] **Step 1: Write failing service tests**

Create `test/models/debt/reconciliation_service_test.rb`:

```ruby
require "test_helper"

class Debt::ReconciliationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @event = DebtEvent.create!(
      account: @account,
      debt_profile: @profile,
      event_type: "interest_accrual",
      status: "pending",
      event_date: Date.new(2026, 1, 31),
      amount: 100,
      currency: "USD"
    )
  end

  test "matches provider interest entry by date and amount" do
    entry = @account.entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 100,
      currency: "USD",
      source: "plaid",
      external_id: "interest-1",
      entryable: Transaction.new
    )

    match = Debt::ReconciliationService.new(@event).call

    assert_equal entry, match.entry
    assert_equal "accepted", match.status
    assert_equal "matched", @event.reload.status
  end

  test "returns nil when no match is found" do
    assert_nil Debt::ReconciliationService.new(@event).call
  end
end
```

Create `test/models/debt/interest_accrual_service_test.rb`:

```ruby
require "test_helper"

class Debt::InterestAccrualServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(
      account: @account,
      auto_accrual_enabled: true,
      last_accrued_on: Date.new(2025, 12, 31)
    )
    @profile.debt_rate_periods.create!(
      rate_type: "fixed",
      annual_rate: 12,
      starts_on: Date.new(2025, 1, 1)
    )
  end

  test "posts monthly interest entry and event" do
    assert_difference -> { Entry.count } => 1, -> { DebtEvent.count } => 1 do
      Debt::InterestAccrualService.new(@profile, through_on: Date.new(2026, 1, 31)).call
    end

    event = DebtEvent.order(:created_at).last
    assert_equal "posted", event.status
    assert_equal "interest_accrual", event.event_type
    assert event.entry.present?
    assert event.entry.amount.positive?
    assert_equal Date.new(2026, 1, 31), @profile.reload.last_accrued_on
  end

  test "does not duplicate same period" do
    service = Debt::InterestAccrualService.new(@profile, through_on: Date.new(2026, 1, 31))

    service.call

    assert_no_difference -> { Entry.count } do
      service.call
    end
  end

  test "matches provider entry instead of posting duplicate" do
    @account.entries.create!(
      date: Date.new(2026, 1, 31),
      name: "Interest Charge",
      amount: 5_000,
      currency: "USD",
      source: "plaid",
      external_id: "interest-provider-1",
      entryable: Transaction.new
    )

    assert_no_difference -> { Entry.count } do
      Debt::InterestAccrualService.new(@profile, through_on: Date.new(2026, 1, 31)).call
    end

    assert_equal "matched", DebtEvent.order(:created_at).last.status
  end

  test "does not post when auto accrual is disabled" do
    @profile.update!(auto_accrual_enabled: false)

    assert_no_difference -> { Entry.count } do
      assert_nil Debt::InterestAccrualService.new(@profile, through_on: Date.new(2026, 1, 31)).call
    end
  end

  test "records successful posting run" do
    assert_difference -> { DebtPostingRun.count } => 1 do
      Debt::InterestAccrualService.new(@profile, through_on: Date.new(2026, 1, 31)).call
    end

    run = DebtPostingRun.order(:created_at).last
    assert_equal @account, run.account
    assert_equal @profile, run.debt_profile
    assert_equal "interest_accrual", run.run_type
    assert_equal "succeeded", run.status
    assert_equal Date.new(2026, 1, 1), run.period_start_on
    assert_equal Date.new(2026, 1, 31), run.period_end_on
    assert run.started_at.present?
    assert run.finished_at.present?
  end
end
```

- [ ] **Step 2: Run tests to verify missing services**

Run:

```bash
bin/rails test test/models/debt/reconciliation_service_test.rb test/models/debt/interest_accrual_service_test.rb
```

Expected: tests fail with missing service constants.

- [ ] **Step 3: Add reconciliation service**

Create `app/models/debt/reconciliation_service.rb`:

```ruby
module Debt
  class ReconciliationService
    def initialize(debt_event)
      @debt_event = debt_event
    end

    def call
      entry = matching_entry
      return nil unless entry

      DebtReconciliationMatch.create!(
        account: debt_event.account,
        debt_event: debt_event,
        entry: entry,
        match_type: "date_amount",
        confidence: "high",
        status: "accepted",
        matched_on: Date.current
      )
    end

    private
      attr_reader :debt_event

      def matching_entry
        debt_event.account.entries
          .where(date: debt_event.event_date, amount: debt_event.amount, currency: debt_event.currency)
          .where.not(source: nil)
          .first
      end
  end
end
```

- [ ] **Step 4: Add interest accrual service**

Create `app/models/debt/interest_accrual_service.rb`:

```ruby
module Debt
  class InterestAccrualService
    def initialize(debt_profile, through_on: Date.current)
      @debt_profile = debt_profile
      @through_on = through_on.to_date
    end

    def call
      return nil unless debt_profile.auto_accrual_enabled?
      return nil unless terms.projectable?
      return existing_event if existing_event.present?

      run = start_run!

      DebtEvent.transaction do
        result = post_or_match_event
        run.update!(status: "succeeded", finished_at: Time.current)
        result
      end
    rescue => error
      run&.update!(
        status: "failed",
        finished_at: Time.current,
        error_class: error.class.name,
        error_message: error.message
      )
      raise
    end

    private
      attr_reader :debt_profile, :through_on

      def account
        debt_profile.account
      end

      def period_start
        anchor_date = debt_profile.last_accrued_on || account.entries.minimum(:date)&.prev_day || through_on.beginning_of_month.prev_day
        anchor_date + 1.day
      end

      def start_run!
        DebtPostingRun.create!(
          account: account,
          debt_profile: debt_profile,
          run_type: "interest_accrual",
          period_start_on: period_start,
          period_end_on: through_on,
          status: "started",
          started_at: Time.current
        )
      end

      def post_or_match_event
        event = build_event
        match = ReconciliationService.new(event).call

        if match
          debt_profile.update!(last_accrued_on: through_on)
          match.debt_event
        else
          entry = create_interest_entry!(event)
          event.update!(entry: entry, status: "posted")
          debt_profile.update!(last_accrued_on: through_on)
          event
        end
      end

      def idempotency_key
        "interest:#{account.id}:#{period_start}:#{through_on}"
      end

      def existing_event
        @existing_event ||= DebtEvent.find_by(account: account, idempotency_key: idempotency_key)
      end

      def terms
        @terms ||= AccountTerms.new(account, as_of: through_on).call
      end

      def amount
        (terms.opening_balance * terms.annual_rate / 100 / 12).round(4)
      end

      def build_event
        DebtEvent.create!(
          account: account,
          debt_profile: debt_profile,
          event_type: "interest_accrual",
          status: "pending",
          event_date: through_on,
          period_start_on: period_start,
          period_end_on: through_on,
          amount: amount,
          currency: account.currency,
          source: "sure",
          idempotency_key: idempotency_key
        )
      end

      def create_interest_entry!(event)
        account.entries.create!(
          date: event.event_date,
          name: "Interest accrual",
          amount: event.amount,
          currency: event.currency,
          source: "sure",
          external_id: event.idempotency_key,
          entryable: Transaction.new(kind: "standard")
        )
      end
  end
end
```

- [ ] **Step 5: Run service tests**

Run:

```bash
bin/rails test test/models/debt/reconciliation_service_test.rb test/models/debt/interest_accrual_service_test.rb
```

Expected: all tests pass.

- [ ] **Step 6: Commit accrual services**

```bash
git add app/models/debt/reconciliation_service.rb app/models/debt/interest_accrual_service.rb test/models/debt/reconciliation_service_test.rb test/models/debt/interest_accrual_service_test.rb
git commit -m "Add debt interest accrual services"
```

## Task 5: Add Obligations And Payment Allocation Services

**Files:**

- Create: `app/models/debt/obligation_service.rb`
- Create: `app/models/debt/payment_allocation_service.rb`
- Test: `test/models/debt/obligation_service_test.rb`
- Test: `test/models/debt/payment_allocation_service_test.rb`

- [ ] **Step 1: Write failing tests**

Create `test/models/debt/obligation_service_test.rb`:

```ruby
require "test_helper"

class Debt::ObligationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:credit_card)
    @profile = DebtProfile.create!(
      account: @account,
      minimum_payment_amount: 100,
      payment_due_day: 15
    )
  end

  test "imports provider obligation idempotently" do
    attributes = {
      due_on: Date.new(2026, 2, 15),
      minimum_payment_amount: 100,
      statement_balance_amount: 1_000,
      currency: "USD",
      source: "plaid",
      external_id: "statement-1"
    }

    first = Debt::ObligationService.new(@profile).import_provider_obligation!(attributes)
    second = Debt::ObligationService.new(@profile).import_provider_obligation!(attributes)

    assert_equal first, second
    assert_equal 1, DebtObligation.where(source: "plaid", external_id: "statement-1").count
  end

  test "generates local obligation when provider data is absent" do
    obligation = Debt::ObligationService.new(@profile, as_of: Date.new(2026, 2, 1)).generate_local_obligation!

    assert_equal Date.new(2026, 2, 15), obligation.due_on
    assert_equal 100.to_d, obligation.minimum_payment_amount
    assert_equal "open", obligation.status
  end
end
```

Create `test/models/debt/payment_allocation_service_test.rb`:

```ruby
require "test_helper"

class Debt::PaymentAllocationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account, auto_payment_allocation_enabled: true)
    @obligation = DebtObligation.create!(
      account: @account,
      debt_profile: @profile,
      due_on: Date.new(2026, 2, 15),
      status: "open",
      minimum_payment_amount: 500,
      interest_due_amount: 100,
      fee_due_amount: 25,
      paid_amount: 0,
      currency: "USD"
    )
    @entry = @account.entries.create!(
      date: Date.new(2026, 2, 10),
      name: "Loan payment",
      amount: -500,
      currency: "USD",
      entryable: Transaction.new(kind: "loan_payment")
    )
  end

  test "allocates payment to fees interest then principal" do
    allocation = Debt::PaymentAllocationService.new(@entry).call

    assert_equal 25.to_d, allocation.fee_amount
    assert_equal 100.to_d, allocation.interest_amount
    assert_equal 375.to_d, allocation.principal_amount
    assert_equal @obligation, allocation.debt_obligation
    assert_equal "paid", @obligation.reload.status
  end

  test "does not allocate unless auto allocation is enabled" do
    @profile.update!(auto_payment_allocation_enabled: false)

    assert_no_difference -> { DebtPaymentAllocation.count } do
      assert_nil Debt::PaymentAllocationService.new(@entry).call
    end
  end
end
```

- [ ] **Step 2: Run tests to verify missing services**

Run:

```bash
bin/rails test test/models/debt/obligation_service_test.rb test/models/debt/payment_allocation_service_test.rb
```

Expected: tests fail with missing service constants.

- [ ] **Step 3: Add obligation service**

Create `app/models/debt/obligation_service.rb`:

```ruby
module Debt
  class ObligationService
    def initialize(debt_profile, as_of: Date.current)
      @debt_profile = debt_profile
      @as_of = as_of.to_date
    end

    def import_provider_obligation!(attributes)
      DebtObligation.find_or_initialize_by(
        account: account,
        source: attributes.fetch(:source),
        external_id: attributes.fetch(:external_id)
      ).tap do |obligation|
        obligation.assign_attributes(
          debt_profile: debt_profile,
          due_on: attributes.fetch(:due_on),
          status: attributes.fetch(:status, "open"),
          statement_balance_amount: attributes[:statement_balance_amount],
          minimum_payment_amount: attributes[:minimum_payment_amount],
          principal_due_amount: attributes[:principal_due_amount],
          interest_due_amount: attributes[:interest_due_amount],
          fee_due_amount: attributes[:fee_due_amount],
          currency: attributes.fetch(:currency),
          extra: attributes.fetch(:extra, {})
        )
        obligation.save!
      end
    end

    def generate_local_obligation!
      DebtObligation.find_or_create_by!(
        account: account,
        debt_profile: debt_profile,
        due_on: due_on,
        source: "sure",
        external_id: "local:#{account.id}:#{due_on}"
      ) do |obligation|
        obligation.status = "open"
        obligation.minimum_payment_amount = debt_profile.minimum_payment_amount
        obligation.currency = account.currency
      end
    end

    private
      attr_reader :debt_profile, :as_of

      def account
        debt_profile.account
      end

      def due_on
        day = debt_profile.payment_due_day || as_of.day
        Date.new(as_of.year, as_of.month, [ day, as_of.end_of_month.day ].min)
      end
  end
end
```

- [ ] **Step 4: Add payment allocation service**

Create `app/models/debt/payment_allocation_service.rb`:

```ruby
module Debt
  class PaymentAllocationService
    def initialize(entry)
      @entry = entry
      @account = entry.account
      @profile = account.debt_profile
    end

    def call
      return existing_allocation if existing_allocation
      return nil unless profile&.auto_payment_allocation_enabled?
      return nil unless entry.amount.negative?

      DebtPaymentAllocation.transaction do
        allocation = DebtPaymentAllocation.create!(
          account: account,
          entry: entry,
          debt_profile: profile,
          debt_obligation: obligation,
          allocation_method: "automatic",
          status: "allocated",
          fee_amount: fee_amount,
          interest_amount: interest_amount,
          principal_amount: principal_amount,
          unapplied_amount: 0,
          currency: entry.currency
        )
        update_obligation!(allocation)
        allocation
      end
    end

    private
      attr_reader :entry, :account, :profile

      def existing_allocation
        @existing_allocation ||= DebtPaymentAllocation.find_by(entry: entry)
      end

      def payment_amount
        entry.amount.abs
      end

      def obligation
        @obligation ||= account.debt_obligations
          .where(status: %w[open partially_paid overdue])
          .where("due_on >= ?", entry.date)
          .order(:due_on)
          .first
      end

      def fee_amount
        [ obligation&.fee_due_amount || 0.to_d, payment_amount ].min
      end

      def interest_amount
        remaining = payment_amount - fee_amount
        [ obligation&.interest_due_amount || 0.to_d, remaining ].min
      end

      def principal_amount
        payment_amount - fee_amount - interest_amount
      end

      def update_obligation!(allocation)
        return unless obligation

        obligation.paid_amount += allocation.component_total
        obligation.status = obligation.paid_amount >= obligation.amount_due ? "paid" : "partially_paid"
        obligation.save!
      end
  end
end
```

- [ ] **Step 5: Run service tests**

Run:

```bash
bin/rails test test/models/debt/obligation_service_test.rb test/models/debt/payment_allocation_service_test.rb
```

Expected: all tests pass.

- [ ] **Step 6: Commit obligation and allocation services**

```bash
git add app/models/debt/obligation_service.rb app/models/debt/payment_allocation_service.rb test/models/debt/obligation_service_test.rb test/models/debt/payment_allocation_service_test.rb
git commit -m "Add debt obligations and payment allocation"
```

## Task 6: Add Account Overview UI

**Files:**

- Create: `app/views/accounts/show/_debt_mechanics.html.erb`
- Create: `app/views/credit_cards/tabs/_overview.html.erb`
- Modify: `app/components/UI/account_page.rb`
- Modify: `app/views/loans/tabs/_overview.html.erb`
- Modify: `config/locales/views/accounts/en.yml`
- Modify: `config/locales/views/credit_cards/en.yml`
- Test: `test/controllers/loans_controller_test.rb`
- Test: `test/controllers/credit_cards_controller_test.rb`

- [ ] **Step 1: Write failing overview tests**

Add to `test/controllers/loans_controller_test.rb`:

```ruby
  test "shows debt mechanics on loan overview" do
    DebtProfile.create!(
      account: @account,
      rate_type: "fixed",
      minimum_payment_amount: 1_000,
      payment_due_day: 15,
      next_due_on: Date.new(2026, 2, 15)
    )

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='debt-mechanics']"
    assert_select "h3", text: I18n.t("accounts.show.debt_mechanics.title")
  end
```

Add to `test/controllers/credit_cards_controller_test.rb`:

```ruby
  test "shows credit card overview tab with debt mechanics" do
    DebtProfile.create!(
      account: @account,
      rate_type: "variable",
      minimum_payment_amount: 100,
      payment_due_day: 20,
      next_due_on: Date.new(2026, 2, 20)
    )

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='debt-mechanics']"
    assert_select "h3", text: I18n.t("accounts.show.debt_mechanics.title")
  end
```

- [ ] **Step 2: Run tests to verify missing UI**

Run:

```bash
bin/rails test test/controllers/loans_controller_test.rb test/controllers/credit_cards_controller_test.rb
```

Expected: credit-card overview test fails because `CreditCard` does not yet expose an overview tab or tab partial.

- [ ] **Step 3: Add debt mechanics partial**

Create `app/views/accounts/show/_debt_mechanics.html.erb`:

```erb
<%# locals: (account:) %>
<% profile = account.debt_profile %>
<% terms = Debt::AccountTerms.new(account).call %>
<% projection = terms.projectable? ? Debt::AccountProjection.new(account).call : nil %>
<% open_obligation = account.debt_obligations.where(status: %w[open partially_paid overdue]).order(:due_on).first %>
<% last_event = account.debt_events.where(status: %w[posted matched]).order(event_date: :desc, created_at: :desc).first %>
<% last_allocation = account.debt_payment_allocations.order(created_at: :desc).first %>

<section data-testid="debt-mechanics" class="space-y-3">
  <div>
    <h3 class="text-primary font-medium"><%= t("accounts.show.debt_mechanics.title") %></h3>
    <p class="text-secondary text-sm"><%= t("accounts.show.debt_mechanics.subtitle") %></p>
  </div>

  <div class="grid grid-cols-3 gap-2">
    <%= summary_card title: t("accounts.show.debt_mechanics.current_rate") do %>
      <% if terms.annual_rate.present? %>
        <%= number_to_percentage(terms.annual_rate, precision: 3) %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.unknown") %>
      <% end %>
    <% end %>

    <%= summary_card title: t("accounts.show.debt_mechanics.minimum_payment") do %>
      <% if terms.monthly_payment.present? %>
        <%= format_money Money.new(terms.monthly_payment, account.currency) %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.unknown") %>
      <% end %>
    <% end %>

    <%= summary_card title: t("accounts.show.debt_mechanics.next_due") do %>
      <% if open_obligation&.due_on.present? %>
        <%= l(open_obligation.due_on, format: :long) %>
      <% elsif profile&.next_due_on.present? %>
        <%= l(profile.next_due_on, format: :long) %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.unknown") %>
      <% end %>
    <% end %>

    <%= summary_card title: t("accounts.show.debt_mechanics.open_amount_due") do %>
      <% if open_obligation.present? %>
        <%= format_money Money.new(open_obligation.amount_due, account.currency) %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.none") %>
      <% end %>
    <% end %>

    <%= summary_card title: t("accounts.show.debt_mechanics.last_interest") do %>
      <% if last_event.present? %>
        <%= format_money Money.new(last_event.amount, last_event.currency) %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.none") %>
      <% end %>
    <% end %>

    <%= summary_card title: t("accounts.show.debt_mechanics.payoff") do %>
      <% if projection.respond_to?(:payoff_on) && projection.payoff_on.present? %>
        <%= l(projection.payoff_on, format: :long) %>
      <% elsif projection.respond_to?(:truncated?) && projection.truncated? %>
        <%= t("accounts.show.debt_mechanics.not_within_horizon") %>
      <% else %>
        <%= t("accounts.show.debt_mechanics.unavailable") %>
      <% end %>
    <% end %>
  </div>

  <% if last_allocation.present? %>
    <p class="text-sm text-secondary">
      <%= t(
        "accounts.show.debt_mechanics.last_allocation",
        principal: format_money(Money.new(last_allocation.principal_amount, last_allocation.currency)),
        interest: format_money(Money.new(last_allocation.interest_amount, last_allocation.currency)),
        fees: format_money(Money.new(last_allocation.fee_amount, last_allocation.currency))
      ) %>
    </p>
  <% end %>
</section>
```

- [ ] **Step 4: Wire overview tabs**

Modify `app/components/UI/account_page.rb`:

```ruby
    when "Property", "Vehicle", "Loan", "CreditCard"
      [ :activity, :overview ]
```

Append to `app/views/loans/tabs/_overview.html.erb` after the edit link:

```erb
<%= render "accounts/show/debt_mechanics", account: account %>
```

Create `app/views/credit_cards/tabs/_overview.html.erb`:

```erb
<%# locals: (account:) %>

<div class="grid grid-cols-3 gap-2">
  <%= summary_card title: t("credit_cards.overview.amount_owed") do %>
    <%= format_money(account.balance_money) %>
  <% end %>

  <%= summary_card title: t("credit_cards.overview.available_credit") do %>
    <%= format_money(account.credit_card.available_credit_money) || t("credit_cards.overview.unknown") %>
  <% end %>

  <%= summary_card title: t("credit_cards.overview.minimum_payment") do %>
    <%= format_money(account.credit_card.minimum_payment_money || Money.new(0, account.currency)) %>
  <% end %>

  <%= summary_card title: t("credit_cards.overview.apr") do %>
    <%= account.credit_card.apr ? number_to_percentage(account.credit_card.apr, precision: 2) : t("credit_cards.overview.unknown") %>
  <% end %>

  <%= summary_card title: t("credit_cards.overview.expiration_date") do %>
    <%= account.credit_card.expiration_date ? l(account.credit_card.expiration_date, format: :long) : t("credit_cards.overview.unknown") %>
  <% end %>

  <%= summary_card title: t("credit_cards.overview.annual_fee") do %>
    <%= format_money(account.credit_card.annual_fee_money || Money.new(0, account.currency)) %>
  <% end %>
</div>

<div class="flex justify-center py-8">
  <%= render DS::Link.new(
    text: t("credit_cards.overview.edit_account_details"),
    variant: "ghost",
    href: edit_credit_card_path(account),
    frame: :modal
  ) %>
</div>

<%= render "accounts/show/debt_mechanics", account: account %>
```

- [ ] **Step 5: Add locale strings**

Add under `accounts.show` in `config/locales/views/accounts/en.yml`:

```yaml
      debt_mechanics:
        title: Debt mechanics
        subtitle: Interest, due dates, payment allocation, and payoff estimates.
        current_rate: Current rate
        minimum_payment: Minimum payment
        next_due: Next due
        open_amount_due: Amount due
        last_interest: Last interest
        payoff: Payoff estimate
        unknown: Unknown
        none: None
        unavailable: Unavailable
        not_within_horizon: Not within 30 years
        last_allocation: "Last payment allocation: %{principal} principal, %{interest} interest, %{fees} fees"
```

If `config/locales/views/credit_cards/en.yml` already has the overview keys at `credit_cards.overview`, keep them. If it does not, add:

```yaml
    overview:
      amount_owed: Amount Owed
      annual_fee: Annual Fee
      apr: APR
      available_credit: Available Credit
      edit_account_details: Edit account details
      expiration_date: Expiration Date
      minimum_payment: Minimum Payment
      unknown: Unknown
```

- [ ] **Step 6: Run controller tests**

Run:

```bash
bin/rails test test/controllers/loans_controller_test.rb test/controllers/credit_cards_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 7: Commit UI**

```bash
git add app/components/UI/account_page.rb app/views/accounts/show/_debt_mechanics.html.erb app/views/loans/tabs/_overview.html.erb app/views/credit_cards/tabs/_overview.html.erb config/locales/views/accounts/en.yml config/locales/views/credit_cards/en.yml test/controllers/loans_controller_test.rb test/controllers/credit_cards_controller_test.rb
git commit -m "Show debt mechanics on account overviews"
```

## Task 7: Add Provider Debt Metadata Hook

**Files:**

- Modify: `app/models/account/provider_import_adapter.rb`
- Modify: `app/models/plaid_account/liabilities/credit_processor.rb`
- Test: `test/models/plaid_account/liabilities/credit_processor_test.rb`
- Test: existing Plaid student-loan and mortgage processor tests as regression coverage.

- [ ] **Step 1: Add a narrow adapter method**

Add this method to `app/models/account/provider_import_adapter.rb` near `update_accountable_attributes`:

```ruby
  def import_debt_obligation(attributes:, source:)
    return false unless account.liability?
    return false if attributes.blank?

    profile = account.debt_profile || account.create_debt_profile!(source: source)
    Debt::ObligationService.new(profile).import_provider_obligation!(
      attributes.merge(source: source)
    )
    true
  rescue => e
    Rails.logger.error("Failed to import debt obligation from #{source}: #{e.message}")
    false
  end
```

- [ ] **Step 2: Route Plaid credit due-date data when present**

Modify `app/models/plaid_account/liabilities/credit_processor.rb` after `update_accountable_attributes`:

```ruby
    if credit_data["next_payment_due_date"].present? || credit_data["last_statement_balance"].present?
      import_adapter.import_debt_obligation(
        attributes: {
          due_on: parse_date(credit_data["next_payment_due_date"]) || Date.current,
          minimum_payment_amount: credit_data["minimum_payment_amount"],
          statement_balance_amount: credit_data["last_statement_balance"],
          currency: account.currency,
          external_id: "plaid-credit-#{plaid_account.plaid_id}-#{credit_data["next_payment_due_date"]}"
        },
        source: "plaid"
      )
    end
```

Add private date parser:

```ruby
    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end
```

- [ ] **Step 3: Extend Plaid liability tests**

Replace the existing "updates credit card minimum payment and APR from Plaid data" test in `test/models/plaid_account/liabilities/credit_processor_test.rb` with:

```ruby
  test "updates credit card terms and imports due-date data from Plaid data" do
    @plaid_account.update!(raw_liabilities_payload: {
      credit: {
        minimum_payment_amount: 100,
        aprs: [ { apr_percentage: 15.0 } ],
        next_payment_due_date: Date.new(2026, 2, 15).to_s,
        last_statement_balance: 1200
      }
    })

    processor = PlaidAccount::Liabilities::CreditProcessor.new(@plaid_account)
    processor.process

    account = @plaid_account.current_account
    assert_equal 100, account.credit_card.minimum_payment
    assert_equal 15.0, account.credit_card.apr

    obligation = @plaid_account.current_account.debt_obligations.last
    assert_equal Date.new(2026, 2, 15), obligation.due_on
    assert_equal 100, obligation.minimum_payment_amount
    assert_equal 1200, obligation.statement_balance_amount
    assert_equal "plaid", obligation.source
  end
```

- [ ] **Step 4: Run provider liability tests**

Run:

```bash
bin/rails test test/models/plaid_account/liabilities/credit_processor_test.rb test/models/plaid_account/liabilities/student_loan_processor_test.rb test/models/plaid_account/liabilities/mortgage_processor_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Commit provider hook**

```bash
git add app/models/account/provider_import_adapter.rb app/models/plaid_account/liabilities/credit_processor.rb test/models/plaid_account/liabilities/credit_processor_test.rb
git commit -m "Import provider debt obligations"
```

## Task 8: Final Verification

**Files:**

- No new files.

- [ ] **Step 1: Run targeted debt tests**

Run:

```bash
bin/rails test \
  test/models/debt_profile_test.rb \
  test/models/debt_rate_period_test.rb \
  test/models/debt_event_test.rb \
  test/models/debt_obligation_test.rb \
  test/models/debt_payment_allocation_test.rb \
  test/models/debt_reconciliation_match_test.rb \
  test/models/debt_posting_run_test.rb \
  test/models/debt/account_terms_test.rb \
  test/models/debt/projection_test.rb \
  test/models/debt/reconciliation_service_test.rb \
  test/models/debt/interest_accrual_service_test.rb \
  test/models/debt/obligation_service_test.rb \
  test/models/debt/payment_allocation_service_test.rb \
  test/controllers/loans_controller_test.rb \
  test/controllers/credit_cards_controller_test.rb \
  test/models/plaid_account/liabilities/credit_processor_test.rb \
  test/models/plaid_account/liabilities/student_loan_processor_test.rb \
  test/models/plaid_account/liabilities/mortgage_processor_test.rb
```

Expected: all targeted tests pass.

- [ ] **Step 2: Run lint and full Rails tests when practical**

Run:

```bash
bin/rubocop
bin/rails test
```

Expected: both commands exit 0. If full test runtime is too high, record the targeted test output and the reason full suite was not run.

- [ ] **Step 3: Confirm forecast files were not touched**

Run:

```bash
git diff --name-only main...HEAD | grep -i forecast || true
```

Expected: no forecast files are listed, except pre-existing docs if this branch includes already committed spec history.

## Plan Self-Review

Spec coverage:

- Debt terms: Tasks 1-3.
- Rate periods: Tasks 1-3.
- Interest accrual persisted through entries: Task 4.
- Payment allocation: Task 5.
- Obligations and due dates: Task 5.
- Reconciliation: Task 4 and Task 7.
- Provider metadata compatibility: Task 7.
- Posting-run audit rows: Tasks 2 and 4.
- Account UI: Task 6.
- Forecast pause: Task 8 confirms no forecast files.

Known implementation sacrifices:

- Provider support starts with Plaid credit obligations because current tests and payloads expose useful fields. Other providers can route through the same adapter method when payloads provide durable due-date or allocation metadata.
- Payment allocation starts deterministic and conservative. Provider-supplied principal/interest splits can override it later through the same allocation table.
- Auto accrual is opt-in. Existing accounts do not change balances until a profile enables posting.
