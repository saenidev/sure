# Federal Student Loan Mode

Federal student loan mode is for manual debt accounts whose servicer cannot be connected.

It supports aggregate subsidized and unsubsidized accounts, tracks principal separately from accrued interest, uses principal-only daily simple interest for federal loan accrual, and treats repayment-plan output as estimates.

The servicer remains the source of truth. Users should periodically update principal and accrued-interest balances from the servicer.

Repayment-plan projections are non-mutating. IBR estimates require supplied income and poverty-guideline assumptions. RAP and Tiered Standard output remains unavailable unless the app has explicit versioned rules with source/date metadata, because those policy details are current and sensitive.
