# Low-Maintenance Debt Terms and Projection Design

## Purpose

Build the first debt feature needed by forecasting with a small initial migration for normalized debt terms, while avoiding duplicated provider data and generated debt history.

The feature should give Sure a reusable, deterministic way to project payoff behavior for existing loans and credit cards. It should use debt data already stored on account-specific models, add an optional override table for normalized terms, show useful payoff estimates on account overview pages, and expose a small backend surface that the later forecasting engine can consume.

## Background

The financial forecasting design calls out debt interest accrual as an upstream dependency before full debt forecasting. The original forecasting foundation plan proposed a new `DebtAssumption` table and a generic debt projection service.

After reviewing the current codebase, the maintenance risk is not the migration itself. The risk is making a new table mirror provider data that already lives on `Loan` and `CreditCard`, then having two records disagree. The lower-maintenance version still adds an initial migration, but treats it as an optional normalized override layer:

- `Loan` already stores `interest_rate`, `rate_type`, `term_months`, and can compute `monthly_payment`.
- `CreditCard` already stores `apr` and `minimum_payment`.
- Provider processors already populate some of these fields from Plaid and SimpleFIN.
- Account pages already have overview surfaces for loans and an unused credit-card overview partial that can be moved into the account tab structure.
- `DebtAssumption` should store explicit debt terms that do not already exist on the account type, or values the user intentionally overrides.

This keeps the database ready for future upstream debt work without forcing every provider sync to maintain a second copy of the same terms. The first version should still be computed-only and non-mutating: it should not create interest transactions, principal rows, or balance history.

## Goals

- Add a `DebtAssumption` table for optional normalized account-level debt terms.
- Add a pure debt projection service that can project monthly interest, payments, closing balances, payoff timing, and total interest.
- Add a small account adapter that extracts projection terms from `DebtAssumption`, existing `Loan` fields, and existing `CreditCard` fields.
- Add payoff estimates to loan and credit-card account overview tabs.
- Keep all projections read-only. Do not create synthetic interest transactions or alter account balances.
- Provide focused tests for projection math, account term extraction, and the account overview UI.

## Non-Goals

- No generated debt schedule persistence in this phase.
- No required `DebtAssumption` record for every liability account.
- No provider sync rewrite beyond consuming the data providers already save.
- No automatic interest-entry creation.
- No due-date-driven cashflow scheduling, promotional APR windows, variable-rate schedules, refinancing, or extra-payment scenarios.
- No forecast timeline UI integration in this phase.
- No broad form rebuild. Existing loan and credit-card edit forms remain the main user-facing term editors.

## Architecture

The feature has four backend units.

`DebtAssumption` is an optional one-to-one record for account-level debt terms. Its columns are nullable where possible because it is an override layer, not a required mirror of provider fields.

`Debt::Projection` is a pure Ruby service. Given opening balance, annual interest rate, monthly payment, start date, and number of months, it returns monthly rows. It does not know about ActiveRecord accounts and does not write data.

`Debt::AccountTerms` is the boundary between Sure account models and debt math. It receives an `Account`, detects whether it is a supported debt type, and returns normalized projection inputs or missing-field information. It resolves values in this order:

1. Explicit non-blank `DebtAssumption` value.
2. Existing account-specific field from `Loan` or `CreditCard`.
3. Missing field.

`Debt::AccountProjection` is a convenience wrapper for account pages and future forecasting code. It combines `Debt::AccountTerms` and `Debt::Projection`, then exposes summary values such as `projectable?`, `missing_fields`, `payoff_month`, `months_to_payoff`, and `total_interest`.

This keeps account-specific debt knowledge out of projection math and keeps UI code from knowing how to interpret every debt account type.

## Database Design

Create `debt_assumptions` with a one-to-one relationship to `accounts`.

Columns:

- `account_id`: required, unique, foreign key.
- `annual_interest_rate`: nullable decimal, percent value such as `18.9900`.
- `rate_type`: nullable string, accepted values `fixed`, `variable`, `adjustable`, `promotional`.
- `accrual_cadence`: nullable string, accepted values `monthly`, `daily`.
- `minimum_payment`: nullable decimal in the account currency.
- `payment_due_day`: nullable integer from 1 to 31.
- `effective_start_on`: nullable date.
- `effective_end_on`: nullable date.
- `extra`: JSONB, default `{}`.
- timestamps.

The table should not include generated principal, interest, or closing-balance rows. Those stay computed until there is a separate product decision to persist real debt events. `payment_due_day` is stored for future upstream compatibility only; this phase should not use it to schedule cashflow.

`Account` should get `has_one :debt_assumption, dependent: :destroy`.

`DebtAssumption` should validate:

- Account is a liability.
- Rate type is present only when included in the allowed values.
- Accrual cadence is present only when included in the allowed values.
- Annual interest rate and minimum payment are greater than or equal to zero when present.
- Payment due day is between 1 and 31 when present.
- Effective end date is not before effective start date.

Do not auto-create `DebtAssumption` records for every existing debt account. That would add write volume and make the table look authoritative when it may only contain empty defaults.

## Supported Accounts

### Loans

Loans are projectable when these values are present:

- Current account balance.
- Fixed `rate_type`.
- `interest_rate`.
- A positive monthly payment from `Loan#monthly_payment`.

The monthly payment comes from the existing loan model unless `DebtAssumption#minimum_payment` is present. The projection uses the current account balance as the opening balance, not the original balance.

Variable or adjustable loans should show that payoff projection is unavailable until Sure supports variable-rate assumptions.

### Credit Cards

Credit cards are projectable when these values are present:

- Current account balance.
- `apr`.
- Positive `minimum_payment`.

The projection assumes no future purchases and uses the minimum payment as the recurring monthly payment unless `DebtAssumption#minimum_payment` is present. This should be labeled as a minimum-payment estimate.

### Other Liabilities

Other liabilities are projectable only when a `DebtAssumption` record supplies the required terms. There should be no new `OtherLiability` form fields in this phase.

## Projection Behavior

Projection should run monthly from the current month by default.

For each month:

1. Use the prior closing balance as opening balance.
2. Accrue interest as `opening_balance * annual_interest_rate / 100 / 12`.
3. Apply the monthly payment, capped so the balance never goes below zero.
4. Stop early when the closing balance reaches zero.

Rows should include:

- `period_start`
- `period_end`
- `opening_balance`
- `accrued_interest`
- `payment`
- `closing_balance`

Summary should include:

- `payoff_month`
- `months_to_payoff`
- `total_interest`
- `final_payment`
- `truncated?` when the balance is not paid off inside the requested horizon

Use a 360-month default horizon. UI should show "Not within 30 years" when the result is truncated.

## UI Design

The account overview should stay quiet and factual.

Loan overview should keep the existing summary cards and add:

- Estimated payoff date.
- Total projected interest.
- Monthly payment used.
- A short unavailable state when required fields are missing or the loan is not fixed-rate.

Credit cards should gain an account overview tab by adding `CreditCard` to `UI::AccountPage#tabs` and placing the credit-card overview partial under `app/views/credit_cards/tabs/_overview.html.erb`. The overview should include current fields plus:

- Minimum-payment payoff estimate.
- Total projected interest.
- A clear unavailable state when APR or minimum payment is missing.

The UI should not add new forms in this phase. Users can already edit loan and credit-card fields through existing account edit modals.

## Error Handling

Projection should fail closed:

- Missing terms return `projectable? == false` with explicit missing field symbols.
- Zero or negative payment returns unavailable rather than looping forever.
- Payment lower than monthly interest should return a truncated projection instead of raising.
- Unsupported account types return unavailable.

The account page should render a stable unavailable message rather than raising if terms are incomplete.

## Files To Edit

Create:

- `db/migrate/YYYYMMDDHHMMSS_create_debt_assumptions.rb`
- `app/models/debt_assumption.rb`
- `app/models/debt/projection.rb`
- `app/models/debt/account_terms.rb`
- `app/models/debt/account_projection.rb`
- `test/models/debt_assumption_test.rb`
- `test/models/debt/projection_test.rb`
- `test/models/debt/account_terms_test.rb`
- `test/models/debt/account_projection_test.rb`
- `app/views/credit_cards/tabs/_overview.html.erb`

Modify:

- `app/models/account.rb`: add `has_one :debt_assumption, dependent: :destroy`.
- `app/components/UI/account_page.rb`: include `CreditCard` in the overview tab list.
- `app/views/loans/tabs/_overview.html.erb`: render payoff projection summary.
- `app/views/credit_cards/_overview.html.erb`: remove after moving content to the account-tab path, if no references remain.
- `config/locales/views/loans/en.yml`: add loan projection strings.
- `config/locales/views/credit_cards/en.yml`: add credit-card projection strings.
- Do not update non-English locale files in this phase. Rails i18n fallbacks are enabled, and this keeps the change small.
- `test/controllers/loans_controller_test.rb`: confirm updated loan fields remain enough for projection.
- `test/controllers/credit_cards_controller_test.rb`: confirm updated credit-card fields remain enough for projection.

No migration should persist projection output or alter existing debt balances.

## Testing

Model tests should cover:

- `DebtAssumption` accepts liability accounts and rejects asset accounts.
- `DebtAssumption` validates rate, cadence, payment, due day, and effective date order.
- Monthly fixed-rate projection with principal, interest, payment, and closing balance.
- Final payment capped at remaining balance plus interest.
- Truncated projection when payment does not amortize the debt.
- Loan term extraction for projectable fixed-rate loans.
- Loan term extraction where `DebtAssumption` overrides monthly payment or interest rate.
- Loan term extraction rejecting variable or adjustable loans.
- Credit-card term extraction for APR plus minimum payment.
- Credit-card term extraction where `DebtAssumption` overrides APR or minimum payment.
- Missing-field reporting for incomplete loan and credit-card accounts.
- `OtherLiability` is unavailable without assumptions and projectable with assumptions.

Controller or integration tests should cover:

- Loan account overview renders payoff estimate when fields are complete.
- Loan account overview renders unavailable state when fixed-rate terms are incomplete.
- Credit-card account overview tab renders existing credit-card fields.
- Credit-card account overview tab renders payoff estimate when APR and minimum payment are present.

## Future Extensions

If later product work needs promotional rate windows, custom minimum-payment rules, extra payments, or hypothetical debt events, add those as additional rows or forecast-specific overrides above `Debt::AccountTerms`.

That future layer should override resolved account terms, not replace the projection engine. The projection math and account-page UI can remain mostly unchanged.

If future upstream provider integrations expose richer debt metadata, they should either continue writing account-specific fields or deliberately write non-blank `DebtAssumption` values through one service. They should not copy every provider value into assumptions by default.
