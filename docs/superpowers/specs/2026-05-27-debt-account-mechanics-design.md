# Debt Account Mechanics Design

## Purpose

Build real debt-account mechanics for unconnected manual liability accounts before any forecasting work resumes.

This feature should let manual loans, manual credit cards, and manual other liabilities store durable terms, accrue interest into the database, split payments into principal/interest/fees, support rate changes and due dates, and reconcile generated records against existing manually-entered account activity. Forecasting and connected-account provider integration remain out of scope for this phase.

## Phasing

This design covers phase 1.

- Phase 1, this project: unconnected manual liability accounts only.
- Future provider phase: connected-account debt metadata, provider statement imports, and provider reconciliation. The phase-1 schema keeps `source`, `external_id`, and `extra` so this can be added later without redesigning the tables.
- Future forecasting phase: forecast scenarios, forecast events, forecast timelines, and assistants consuming the persisted debt mechanics.

Phase 1 should not modify provider import code or forecast code.

## Scope

In scope:

- Debt terms for unconnected manual loans, credit cards, and other liabilities.
- Interest accrual posting into account history.
- Principal, interest, and fee allocation for manually-entered debt payments.
- Rate periods for fixed, variable, adjustable, and promotional rates.
- Payment due-day metadata, statements, obligations, and minimum-payment terms.
- Reconciliation rules so generated debt activity does not duplicate existing manual entries.
- UI surfaces for configuring debt terms and reviewing generated debt activity.

Out of scope:

- Connected accounts and provider sync integration.
- Plaid, SimpleFIN, Lunchflow, Enable Banking, or Sophtron liability metadata import.
- Forecast scenarios, forecast events, forecast runs, forecast timeline UI, and forecast persistence.
- Investment or market forecasting.
- Debt payoff recommendations from Hermes or other assistants.

## Core Product Choice

The database can support high-maintenance debt features without becoming brittle if financial truth stays anchored to Sure's existing ledger.

`Entry` and `Transaction` remain the actual account-history records that affect balances. New debt tables should annotate, generate, reconcile, and allocate those entries. They should not become a second independent balance ledger.

This is the main compatibility rule:

- An interest accrual that affects a liability balance is an `Entry` + `Transaction` on the liability account, linked from a debt event.
- A debt payment that affects a liability balance is still an `Entry` + `Transaction` on the liability account, linked to a payment allocation.
- Debt tables explain why those entries exist and how payment amounts split between principal, interest, and fees.

## Sacrifices For Compatibility

These are deliberate tradeoffs.

- The migration is wider. Real accrual and allocation need several additive tables, not one assumptions table.
- Database constraints should be conservative. Use string types plus model validations for rate/event/source kinds so future providers can add new values without a migration.
- Most new columns should be nullable except foreign keys, amounts that are required for a concrete row, and timestamps. This keeps future provider backfills and partial metadata safe without implementing provider support now.
- `Entry` remains the balance source of truth. Debt tables must reconcile with entries instead of replacing them, which adds implementation complexity.
- Automatic accrual should default off for existing accounts until a user or setup flow confirms terms. This avoids silently changing historical balances.
- Connected accounts should not enable debt automation in phase 1. Provider-imported payments remain governed by existing import behavior until a later provider-specific project.
- Existing `Loan` and `CreditCard` columns stay in place. New debt terms can override them, but should not force a risky data migration on day one.

## Data Model

### `debt_profiles`

One optional profile per liability account. This is the account-level control record.

Columns:

- `account_id`: required, unique, foreign key.
- `status`: string, default `active`.
- `auto_accrual_enabled`: boolean, default `false`.
- `auto_payment_allocation_enabled`: boolean, default `false`.
- `rate_type`: nullable string.
- `accrual_cadence`: nullable string, expected values such as `daily` or `monthly`.
- `compounding_cadence`: nullable string.
- `minimum_payment_amount`: nullable decimal.
- `minimum_payment_percent`: nullable decimal.
- `payment_due_day`: nullable integer.
- `statement_closing_day`: nullable integer.
- `grace_period_days`: nullable integer.
- `effective_start_on`: nullable date.
- `effective_end_on`: nullable date.
- `last_accrued_on`: nullable date.
- `next_due_on`: nullable date.
- `source`: nullable string.
- `extra`: JSONB, default `{}`.
- timestamps.

Validations:

- Account must be a liability.
- One profile per account.
- Day fields must be 1-31 when present.
- Rates, percentages, and amounts must be non-negative when present.
- End date must not be before start date.

### `debt_rate_periods`

Stores current, historical, and promotional rate periods. This avoids overloading one profile row with every possible rate rule.

Columns:

- `debt_profile_id`: required, foreign key.
- `rate_type`: required string.
- `annual_rate`: required decimal.
- `starts_on`: required date.
- `ends_on`: nullable date.
- `priority`: integer, default `0`.
- `source`: nullable string.
- `external_id`: nullable string.
- `extra`: JSONB, default `{}`.
- timestamps.

Indexes:

- `debt_profile_id, starts_on`.
- `debt_profile_id, source, external_id`, unique where source and external ID are present.

Validation:

- Date ranges cannot overlap for the same profile and priority.
- Annual rate must be non-negative.

### `debt_events`

Records generated or user-observed debt mechanics. These rows link debt logic to ledger entries.

Columns:

- `account_id`: required, foreign key.
- `debt_profile_id`: nullable foreign key.
- `entry_id`: nullable foreign key.
- `event_type`: required string, examples: `interest_accrual`, `fee`, `principal_adjustment`, `rate_change`, `manual_adjustment`, `user_observed`.
- `status`: required string, examples: `pending`, `posted`, `matched`, `voided`, `superseded`.
- `event_date`: required date.
- `period_start_on`: nullable date.
- `period_end_on`: nullable date.
- `amount`: required decimal.
- `currency`: required string.
- `source`: nullable string.
- `external_id`: nullable string.
- `idempotency_key`: nullable string.
- `extra`: JSONB, default `{}`.
- timestamps.

Indexes:

- `account_id, event_date`.
- `account_id, event_type, status`.
- `account_id, idempotency_key`, unique where `idempotency_key` is present.
- `account_id, source, external_id`, unique where both are present.

Rules:

- Posted interest and fee events that affect balances must link to an `Entry`.
- Pending events may exist before posting.
- Voided events should not affect account pages except audit views.

### `debt_obligations`

Stores statement-like payment obligations from user-entered or generated debt mechanics. This keeps due dates and statement balances durable without making forecast tables.

Columns:

- `account_id`: required, foreign key.
- `debt_profile_id`: nullable foreign key.
- `statement_on`: nullable date.
- `period_start_on`: nullable date.
- `period_end_on`: nullable date.
- `due_on`: required date.
- `status`: required string, examples: `open`, `partially_paid`, `paid`, `overdue`, `waived`, `superseded`.
- `statement_balance_amount`: nullable decimal.
- `minimum_payment_amount`: nullable decimal.
- `principal_due_amount`: nullable decimal.
- `interest_due_amount`: nullable decimal.
- `fee_due_amount`: nullable decimal.
- `paid_amount`: decimal, default `0`.
- `currency`: required string.
- `source`: nullable string.
- `external_id`: nullable string.
- `extra`: JSONB, default `{}`.
- timestamps.

Indexes:

- `account_id, due_on`.
- `account_id, status`.
- `account_id, due_on, source, external_id`, unique where source and external ID are present.

Rules:

- User-observed obligations should not be overwritten by generated obligations unless a reconciliation service accepts the match.
- Obligations track what was due; they do not change balances by themselves.
- Payments can be linked to obligations through payment allocations.

### `debt_payment_allocations`

Splits one debt payment entry into principal, interest, fees, and optional unapplied amount.

Columns:

- `account_id`: required, foreign key.
- `entry_id`: required, unique foreign key.
- `debt_profile_id`: nullable foreign key.
- `debt_obligation_id`: nullable foreign key.
- `allocation_method`: required string, examples: `automatic`, `manual`.
- `status`: required string, examples: `allocated`, `estimated`, `needs_review`, `voided`.
- `principal_amount`: decimal, default `0`.
- `interest_amount`: decimal, default `0`.
- `fee_amount`: decimal, default `0`.
- `unapplied_amount`: decimal, default `0`.
- `currency`: required string.
- `source`: nullable string.
- `external_id`: nullable string.
- `extra`: JSONB, default `{}`.
- timestamps.

Rules:

- The linked entry must belong to the same account.
- Amount components must be non-negative.
- Component sum should equal the payment magnitude unless status is `needs_review`.
- Allocations should never change the entry amount directly.

### `debt_reconciliation_matches`

Links generated debt events to existing manual entries when Sure detects that a generated accrual or fee was already entered by the user.

Columns:

- `account_id`: required, foreign key.
- `debt_event_id`: required, foreign key.
- `entry_id`: required, foreign key.
- `match_type`: required string, examples: `exact`, `date_amount`, `manual`.
- `confidence`: required string, examples: `high`, `medium`, `low`.
- `status`: required string, examples: `accepted`, `dismissed`, `needs_review`.
- `matched_on`: nullable date.
- `extra`: JSONB, default `{}`.
- timestamps.

Rules:

- Accepted matches mark the generated event as `matched` rather than posting a duplicate entry.
- Manual dismissal prevents repeated suggestions for the same pair.

### `debt_posting_runs`

Tracks background job executions for idempotency and auditability.

Columns:

- `account_id`: required, foreign key.
- `debt_profile_id`: nullable foreign key.
- `run_type`: required string, examples: `interest_accrual`, `payment_allocation`, `obligation_generation`, `reconciliation`.
- `period_start_on`: nullable date.
- `period_end_on`: nullable date.
- `status`: required string.
- `started_at`: nullable datetime.
- `finished_at`: nullable datetime.
- `error_class`: nullable string.
- `error_message`: nullable text.
- `extra`: JSONB, default `{}`.
- timestamps.

Indexes:

- `account_id, run_type, period_start_on, period_end_on`.

## Existing Model Integration

`Account`:

- Add `has_one :debt_profile`.
- Add helpers such as `debt_mechanics_supported?`, `debt_mechanics_enabled?`, and `manual_debt_account?`.

`Loan`:

- Keep existing `interest_rate`, `rate_type`, `term_months`, and `initial_balance`.
- `Debt::AccountTerms` should use loan fields when no profile/rate period override exists.
- Monthly payment can still use `Loan#monthly_payment`, unless the profile has an explicit minimum payment.

`CreditCard`:

- Keep existing `apr`, `minimum_payment`, `available_credit`, `annual_fee`, and `expiration_date`.
- `Debt::AccountTerms` should use card fields when no profile/rate period override exists.
- Credit-card allocations should account for fees separately from interest when fee events exist.

`OtherLiability`:

- Supported through `DebtProfile` only.
- No new other-liability columns are needed.

`Transaction`:

- Keep existing kinds.
- Add debt metadata through linked debt tables, not by stuffing all allocation details into `transactions.extra`.
- Consider a new transaction kind only if UI/reporting needs it. The first implementation can classify generated interest and fees as standard liability transactions with debt-event links.

## Posting Behavior

### Interest Accrual

The accrual service should:

1. Find enabled debt profiles for unconnected manual liability accounts.
2. Determine the accrual window from `last_accrued_on`, account start date, and current date.
3. Resolve the applicable rate period for each day or month.
4. Calculate accrued interest.
5. Search for matching existing manual interest entries first.
6. If a manual match exists, create a reconciliation match and mark the debt event `matched`.
7. If no match exists and auto posting is enabled, create an `Entry` + `Transaction` on the liability account and link a posted `DebtEvent`.
8. Update `last_accrued_on` only after successful posting or matching.

Interest entries increase liability balances, so they should use positive amounts on liability accounts.

### Fees

Fees should use the same event path as interest:

- Existing manually-entered fees can be matched.
- Manually entered or generated fees can create entries.
- Fee events should be allocatable from future payments.

### Payment Allocation

The allocation service should:

1. Find unconnected manual liability-account payment entries.
2. Skip entries with accepted allocations unless recalculation is explicitly requested.
3. Allocate payment magnitude to fees first, then accrued interest, then principal.
4. Link the allocation to the open obligation when one can be matched by due date and amount.
5. Store the split in `debt_payment_allocations`.
6. Update obligation paid amount and status when linked.
7. Mark low-confidence allocations as `estimated` or `needs_review`.

Payment allocations explain payments; they should not create new entries.

### Obligations

The obligation service should:

1. Generate obligations from local profile terms or user-entered statement details.
2. Avoid duplicate obligations by account, due date, source, and external ID.
3. Mark obligations paid when linked allocations cover the amount due.
4. Mark obligations overdue only from a background check, not during read-only page rendering.

Obligations support real debt account operations. They are not forecast events.

### Principal

Principal is persisted as the principal component of `debt_payment_allocations`. The liability account balance still changes through the payment `Entry`.

For manual principal adjustments that are not payments, use a `DebtEvent` linked to an adjustment entry.

## UI Design

Account overview pages should show a debt mechanics section for loans, credit cards, and supported other liabilities.

Show:

- Current principal balance from account balance.
- Current interest rate and rate source.
- Accrued interest since last posted accrual.
- Next due date when configured.
- Current open obligation and amount due.
- Minimum payment.
- Last posted interest event.
- Recent payment allocation: principal, interest, fees.
- Reconciliation warnings when generated and manually-entered activity may duplicate.

Editing should be conservative:

- Add or edit debt terms from an account details modal or a focused debt settings section.
- Keep existing loan and credit-card fields visible.
- Do not require users to configure advanced rate periods unless they need them.
- Require explicit confirmation before enabling automatic interest posting.

Review surfaces:

- A list of generated pending debt events before posting.
- A list of open and overdue obligations.
- A list of low-confidence reconciliation matches.
- A list of payments that need allocation review.

## Manual Account Boundary

Phase 1 is explicitly for unconnected manual accounts.

Rules:

- Debt tables and core debt models should remain liability-wide for future compatibility. Do not encode manual-only as a database constraint or core model validation.
- Debt mechanics UI should only appear for liability accounts with no account-provider connection.
- Debt automation services should return without posting when the account is connected to Plaid, SimpleFIN, Lunchflow, Enable Banking, Sophtron, or another provider.
- Provider processors and `Account::ProviderImportAdapter` should not be modified in this phase.
- Existing connected-account `Loan` and `CreditCard` provider behavior stays as-is.
- Schema fields such as `source`, `external_id`, and `extra` remain so a later provider-specific project can integrate without a migration rewrite.

## Migration Compatibility Guidelines

- Use UUID foreign keys matching the current schema.
- Make the migration additive only.
- Avoid deleting or changing existing `Loan` and `CreditCard` columns.
- Avoid DB-level enum types and rigid check constraints for event/status/source strings.
- Add unique partial indexes for idempotency keys and provider external IDs.
- Keep `extra` JSONB on every new debt table for provider compatibility.
- Use app-level validations for business rules that may evolve.
- Backfill nothing automatically in the migration. Any historical reconstruction should be a separate, reviewable task.

## Error Handling

- Generated postings must be idempotent by account, period, and event type.
- If posting creates an entry but debt-event save fails, the transaction must roll back.
- If manual reconciliation is ambiguous, create a `needs_review` match rather than posting.
- If account terms are incomplete, do not accrue interest automatically.
- If rate periods overlap, block save at the model layer.
- If payment allocation does not balance, mark it `needs_review` instead of forcing bad math.

## Files To Edit

Create:

- `db/migrate/YYYYMMDDHHMMSS_create_debt_mechanics_tables.rb`
- `app/models/debt_profile.rb`
- `app/models/debt_rate_period.rb`
- `app/models/debt_event.rb`
- `app/models/debt_obligation.rb`
- `app/models/debt_payment_allocation.rb`
- `app/models/debt_reconciliation_match.rb`
- `app/models/debt_posting_run.rb`
- `app/models/debt/account_terms.rb`
- `app/models/debt/interest_accrual_service.rb`
- `app/models/debt/payment_allocation_service.rb`
- `app/models/debt/obligation_service.rb`
- `app/models/debt/reconciliation_service.rb`
- Matching model and service tests under `test/models/debt*`.
- Account overview partials for debt mechanics where existing views need them.

Modify:

- `app/models/account.rb`: debt associations and helpers.
- `app/models/loan.rb`: expose debt term defaults through existing methods.
- `app/models/credit_card.rb`: expose debt term defaults through existing methods.
- Loan, credit-card, and other-liability overview views.
- English locale files for new UI copy.

Do not modify forecast models, forecast views, or forecast routes in this feature.

## Testing

Model tests:

- Debt profile accepts liability accounts and rejects asset accounts.
- Rate periods validate non-overlap.
- Debt events require idempotent posting keys when generated.
- Debt obligations deduplicate by account, source, external ID, and due date.
- Payment allocations validate component sums.
- Reconciliation matches prevent duplicate accepted matches.

Service tests:

- Interest accrual posts an entry and debt event for a configured loan.
- Interest accrual matches an existing manual interest transaction instead of duplicating it.
- Interest accrual is idempotent when run twice for the same period.
- Payment allocation splits payment to fees, then interest, then principal.
- Obligation service generates a local obligation from user-entered profile terms.
- Payment allocation marks ambiguous splits as `needs_review`.
- Variable/promotional rates resolve by date.
- Debt mechanics do not render or post for connected liability accounts.

Controller or integration tests:

- Debt terms can be configured for a liability account.
- Auto accrual requires explicit enablement.
- Account overview shows last accrual, payment allocation, and warnings.
- Account overview shows open obligation and due date.
- Other liabilities remain inert until a debt profile is configured.

## Future Forecast Integration

Forecasting should later consume:

- Resolved debt terms.
- Persisted debt events.
- Payment allocations.
- Open obligations and due dates.
- Future payoff projections built from current terms, events, allocations, and obligations.

Forecasting should not create these tables or own debt mechanics. It should treat this feature as the upstream debt source.
