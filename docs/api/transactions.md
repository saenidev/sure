# Transactions API Documentation

The Transactions API allows external applications to manage financial transactions within Sure. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/transactions_spec.rb`](../../spec/requests/api/v1/transactions_spec.rb). These specs authenticate against the Rails stack, exercise every transaction endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  SWAGGER_DRY_RUN=0 bundle exec rspec spec/requests --format Rswag::Specs::SwaggerFormatter
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/transactions_spec.rb
  ```

## Authentication requirements

All transaction endpoints require an OAuth2 access token or API key that grants the appropriate scope (`read` or `read_write`).

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/transactions` | `read` | List transactions with filtering and pagination. |
| `GET /api/v1/transactions/{id}` | `read` | Retrieve a single transaction with full details. |
| `POST /api/v1/transactions` | `write` | Create a new transaction. |
| `PATCH /api/v1/transactions/{id}` | `write` | Update an existing transaction. |
| `DELETE /api/v1/transactions/{id}` | `write` | Permanently delete a transaction. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (pagination, errors, accounts, categories, merchants, tags), and security definitions.

## Filtering options

The `GET /api/v1/transactions` endpoint supports the following query parameters for filtering:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100) |
| `account_id` | uuid | Filter by a single account ID |
| `account_ids[]` | uuid[] | Filter by multiple account IDs |
| `category_id` | uuid | Filter by a single category ID |
| `category_ids[]` | uuid[] | Filter by multiple category IDs |
| `merchant_id` | uuid | Filter by a single merchant ID |
| `merchant_ids[]` | uuid[] | Filter by multiple merchant IDs |
| `tag_ids[]` | uuid[] | Filter by tag IDs |
| `start_date` | date | Filter transactions from this date (inclusive) |
| `end_date` | date | Filter transactions until this date (inclusive) |
| `min_amount` | number | Filter by minimum amount |
| `max_amount` | number | Filter by maximum amount |
| `type` | string | Filter by transaction type: `income` or `expense` |
| `search` | string | Search by name, notes, or merchant name |
| `updated_since` | datetime | Only transactions created or changed at or after this ISO 8601 timestamp |

The list includes excluded transactions (check `excluded`), so a poller sees a
pending entry flip to settled. See [Pending purchases from iPhone Shortcuts](#pending-purchases-from-iphone-shortcuts).

## Transaction object

A transaction response includes:

```json
{
  "id": "uuid",
  "date": "2024-01-15",
  "amount": "$75.50",
  "currency": "USD",
  "name": "Grocery shopping",
  "notes": "Weekly groceries",
  "classification": "expense",
  "external_id": null,
  "source": null,
  "pending": false,
  "excluded": false,
  "shortcut": null,
  "account": {
    "id": "uuid",
    "name": "Checking Account",
    "account_type": "depository"
  },
  "category": {
    "id": "uuid",
    "name": "Groceries",
    "classification": "expense",
    "color": "#4CAF50",
    "icon": "shopping-cart"
  },
  "merchant": {
    "id": "uuid",
    "name": "Whole Foods"
  },
  "tags": [
    {
      "id": "uuid",
      "name": "Essential",
      "color": "#2196F3"
    }
  ],
  "transfer": null,
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Creating transactions

When creating a transaction, the `nature` field determines how the amount is stored:

| Nature | Behaviour |
| --- | --- |
| `income` / `inflow` | Amount is stored as negative (credit) |
| `expense` / `outflow` | Amount is stored as positive (debit) |

Example request body:

```json
{
  "transaction": {
    "account_id": "uuid",
    "date": "2024-01-15",
    "amount": 75.50,
    "name": "Grocery shopping",
    "nature": "expense",
    "category_id": "uuid",
    "merchant_id": "uuid",
    "tag_ids": ["uuid", "uuid"]
  }
}
```

## Pending purchases from iPhone Shortcuts

An iPhone Shortcut can record a purchase the moment it happens, before the bank
reports it. Use a `read_write` API key for the phone, and a separate `read` key
for programs that only read spending.

Two automations post to `POST /api/v1/transactions`:

- **Apple Pay tap**: a *Transaction* (Wallet) automation, `origin: "apple_pay"`.
  Send the merchant name and the amount and currency the Wallet shows (a tap
  abroad shows the local currency, e.g. KRW).
- **Bank alert**: a *Message* or *Email* automation that reads the card's
  per-purchase alert, `origin: "bank_alert"`. Send the amount in the account
  currency.

```http
POST /api/v1/transactions
X-Api-Key: <phone read_write key>
Content-Type: application/json

{
  "transaction": {
    "account_id": "<Chase account uuid>",
    "pending": true,
    "client_id": "6F1C2A4E-3B7D-4C55-9E1A-2D8B0F6A7C10",
    "origin": "apple_pay",
    "occurred_at": "2026-10-11T14:03:00+09:00",
    "name": "Blue Bottle Coffee",
    "amount": 12000,
    "currency": "KRW"
  }
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `pending` | yes | `true` |
| `client_id` | yes | Unique per purchase report; generate a UUID in the Shortcut. Retrying with the same id returns the existing entry with `200`. |
| `origin` | yes | `apple_pay` or `bank_alert` |
| `occurred_at` | yes | ISO 8601 with UTC offset (Shortcuts' *Current Date* formatted as ISO 8601). The entry is dated on this local date unless `date` is sent. |
| `name` | yes | Merchant name |
| `amount` | yes | Positive for a purchase; send `nature: "income"` for a refund |
| `currency` | no | Defaults to the account currency. A different currency is converted to the account currency at the purchase date; the original is kept. |
| `original_amount`, `original_currency` | no | The foreign amount, when `amount` is already in the account currency (an alert that shows both) |

Responses:

- `201`: a new pending entry.
- `200`: a retry of a known `client_id`, or a hint from the other origin folded
  into the existing entry. A tap and an alert on the same account, with the
  same amount (within 5 % when either was converted) and `occurred_at` within
  15 minutes of each other, are one purchase. The Apple Pay merchant name and
  the alert's amount win. Two hints from the same origin never fold.

Without an exchange rate the entry is still recorded in the original currency,
with `shortcut.conversion: "unconverted"`.

### Settlement

When the bank's posted transaction arrives (SimpleFIN, Plaid, Lunch Flow or any
other provider sync on the same account), Sure settles the hint. The hint is
excluded rather than deleted, and both sides link to each other:

- The hint: `pending: false`, `excluded: true`, `shortcut.status: "settled"`,
  `shortcut.settled_by_transaction_id`, `shortcut.settlement_match`
  (`exact`, `fx`, `tip` or `manual`).
- The posted transaction: `shortcut.matched_pending_transaction_id`.

A posted transaction settles a hint when the amount matches exactly (within
5 % for converted amounts), dated from one day before the hint (time zones) to
eight days after. A posted amount up to 25 % higher (a tip) settles within
three days if the merchant names match. A pair settles only when it is
unambiguous both ways; otherwise the hint stays pending until the user merges
it by hand (also recorded as a settlement). A bank's own pending version never
settles a hint: only its posted version does.

A hint that is never settled is excluded after eight days on SimpleFIN-linked
accounts (`shortcut.status: "excluded"` with no `settled_by_transaction_id`).

### Polling for changes

Poll `GET /api/v1/transactions?updated_since=<timestamp>` with a `read` key.
Use the time of your previous poll minus a small overlap (a minute), and
de-duplicate by `id`: a settlement updates both the hint and the posted
transaction, so both appear.

Deleting a transaction by hand removes it without a trace in this list. A
poller that tracks pending ids should treat `GET /api/v1/transactions/{id}`
returning `404` as "deleted". Settled, merged and stale hints are never
deleted by Sure; only a user (UI or `DELETE`) can do that.

## Transfer transactions

If a transaction is part of a transfer between accounts, the `transfer` field will be populated with details about the linked transaction:

```json
{
  "transfer": {
    "id": "uuid",
    "amount": "$500.00",
    "currency": "USD",
    "other_account": {
      "id": "uuid",
      "name": "Savings Account",
      "account_type": "depository"
    }
  }
}
```

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "error_code",
  "message": "Human readable error message",
  "errors": ["Optional array of validation errors"]
}
```

Common error codes include `unauthorized`, `not_found`, `validation_failed`, and `internal_server_error`.
