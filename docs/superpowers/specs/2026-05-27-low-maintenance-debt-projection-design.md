# Low-Maintenance Debt Projection Design

## Purpose

Build the first debt feature needed by forecasting without introducing a second source of truth for debt terms.

The feature should give Sure a reusable, deterministic way to project payoff behavior for existing loans and credit cards. It should use debt data already stored on account-specific models, show useful payoff estimates on account overview pages, and expose a small backend surface that the later forecasting engine can consume.

## Background

The financial forecasting design calls out debt interest accrual as an upstream dependency before full debt forecasting. The original forecasting foundation plan proposed a new `DebtAssumption` table and a generic debt projection service.

After reviewing the current codebase, the lower-maintenance path is to avoid a new assumptions table for now:

- `Loan` already stores `interest_rate`, `rate_type`, `term_months`, and can compute `monthly_payment`.
- `CreditCard` already stores `apr` and `minimum_payment`.
- Provider processors already populate some of these fields from Plaid and SimpleFIN.
- Account pages already have overview surfaces for loans and an unused credit-card overview partial that can be moved into the account tab structure.

Adding a new `DebtAssumption` model now would duplicate fields, require sync ownership rules, and make future maintenance harder. The first version should be computed-only and non-mutating.

## Goals

- Add a pure debt projection service that can project monthly interest, payments, closing balances, payoff timing, and total interest.
- Add a small account adapter that extracts projection terms from existing `Loan` and `CreditCard` fields.
- Add payoff estimates to loan and credit-card account overview tabs.
- Keep all projections read-only. Do not create synthetic interest transactions or alter account balances.
- Provide focused tests for projection math, account term extraction, and the account overview UI.

## Non-Goals

- No `DebtAssumption` table in this phase.
- No support for `OtherLiability` projections unless it later gains real debt term fields.
- No automatic interest-entry creation.
- No due-date modeling, promotional APR windows, variable-rate schedules, refinancing, or extra-payment scenarios.
- No forecast timeline UI integration in this phase.
- No provider sync rewrite beyond consuming the data providers already save.

## Architecture

The feature has three backend units.

`Debt::Projection` is a pure Ruby service. Given opening balance, annual interest rate, monthly payment, start date, and number of months, it returns monthly rows. It does not know about ActiveRecord accounts and does not write data.

`Debt::AccountTerms` is the boundary between Sure account models and debt math. It receives an `Account`, detects whether it is a supported debt type, and returns normalized projection inputs or missing-field information.

`Debt::AccountProjection` is a convenience wrapper for account pages and future forecasting code. It combines `Debt::AccountTerms` and `Debt::Projection`, then exposes summary values such as `projectable?`, `missing_fields`, `payoff_month`, `months_to_payoff`, and `total_interest`.

This keeps account-specific debt knowledge out of projection math and keeps UI code from knowing how to interpret every debt account type.

## Supported Accounts

### Loans

Loans are projectable when these values are present:

- Current account balance.
- Fixed `rate_type`.
- `interest_rate`.
- A positive monthly payment from `Loan#monthly_payment`.

The monthly payment comes from the existing loan model. The projection uses the current account balance as the opening balance, not the original balance.

Variable or adjustable loans should show that payoff projection is unavailable until Sure supports variable-rate assumptions.

### Credit Cards

Credit cards are projectable when these values are present:

- Current account balance.
- `apr`.
- Positive `minimum_payment`.

The projection assumes no future purchases and uses the minimum payment as the recurring monthly payment. This should be labeled as a minimum-payment estimate.

### Other Liabilities

Other liabilities remain unsupported in this phase. They do not currently store interest rate or payment terms. Adding projection support would require new fields, which conflicts with the low-maintenance scope.

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

- `app/models/debt/projection.rb`
- `app/models/debt/account_terms.rb`
- `app/models/debt/account_projection.rb`
- `test/models/debt/projection_test.rb`
- `test/models/debt/account_terms_test.rb`
- `test/models/debt/account_projection_test.rb`
- `app/views/credit_cards/tabs/_overview.html.erb`

Modify:

- `app/components/UI/account_page.rb`: include `CreditCard` in the overview tab list.
- `app/views/loans/tabs/_overview.html.erb`: render payoff projection summary.
- `app/views/credit_cards/_overview.html.erb`: remove after moving content to the account-tab path, if no references remain.
- `config/locales/views/loans/en.yml`: add loan projection strings.
- `config/locales/views/credit_cards/en.yml`: add credit-card projection strings.
- Do not update non-English locale files in this phase. Rails i18n fallbacks are enabled, and this keeps the change small.
- `test/controllers/loans_controller_test.rb`: confirm updated loan fields are enough for projection.
- `test/controllers/credit_cards_controller_test.rb`: confirm updated credit-card fields are enough for projection.

No migration is required.

## Testing

Model tests should cover:

- Monthly fixed-rate projection with principal, interest, payment, and closing balance.
- Final payment capped at remaining balance plus interest.
- Truncated projection when payment does not amortize the debt.
- Loan term extraction for projectable fixed-rate loans.
- Loan term extraction rejecting variable or adjustable loans.
- Credit-card term extraction for APR plus minimum payment.
- Missing-field reporting for incomplete loan and credit-card accounts.
- Unsupported account handling for `OtherLiability`.

Controller or integration tests should cover:

- Loan account overview renders payoff estimate when fields are complete.
- Loan account overview renders unavailable state when fixed-rate terms are incomplete.
- Credit-card account overview tab renders existing credit-card fields.
- Credit-card account overview tab renders payoff estimate when APR and minimum payment are present.

## Future Extensions

If later product work needs due dates, promotional rates, custom minimum-payment rules, extra payments, or hypothetical debt events, add a `DebtAssumption` or forecast-specific override layer above `Debt::AccountTerms`.

That future layer should override account terms, not replace the projection engine. The projection math and account-page UI can remain mostly unchanged.
