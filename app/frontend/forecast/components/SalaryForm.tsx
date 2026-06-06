// Forecast V2 salary assumption form (slice C7; extracted for slice F12).
//
// The assumption-specific form schema + field rendering the typed editor drawer
// composes (spec "Editor Contracts": "editors compose an assumption-specific form
// schema"). Split out of `AssumptionEditor` so the drawer stays type-agnostic
// chrome (header / footer / dirty-close warning / focus trap) and this module owns
// exactly one concern — the salary form schema and how it renders (spec "Frontend
// module responsibility rules"; ~250-line cap). The salary form is the only
// interactive editor in the MVP, so an unknown `form_key` renders a neutral
// "unsupported" body here rather than the drawer guessing a layout.
//
// Tokens only — no raw palette; copy resolves through the client i18n table (`ft`).
// The money amount input carries `privacy-sensitive` so the app-wide privacy
// toggle blurs it with no forecast-specific JS. The form reports edits via
// `onDirty` and submits via `onSubmit`; the drawer owns the save flow itself.

import type { JSX } from "react";
import { ft } from "../i18n";
import type {
  EditorFieldErrors,
  EditorPrefillReadModel,
} from "../types/readModels";

// One field in a composed form schema. `options` makes it a select; otherwise the
// `type` drives an <input>. `param` reads/writes the value from the prefill's
// `params` bag; otherwise it reads a top-level primary value.
interface EditorField {
  readonly name: string;
  readonly labelKey: string;
  readonly type: "text" | "number" | "date" | "select";
  readonly param?: boolean;
  readonly options?: ReadonlyArray<{
    readonly value: string;
    readonly labelKey: string;
  }>;
}

// The salary form schema (spec "Initial Assumption Type Catalog" -> salary: name,
// amount, currency, earner, gross/net, frequency, growth, timing). The shell keeps
// the primary financial fields visible — no advanced disclosure hides amount,
// timing, or treatment (spec "Editor Contracts").
const SALARY_SCHEMA: ReadonlyArray<EditorField> = [
  {
    name: "name",
    labelKey: "forecasts.editor.salary.name_label",
    type: "text",
  },
  {
    name: "amount",
    labelKey: "forecasts.editor.salary.amount_label",
    type: "number",
  },
  {
    name: "currency",
    labelKey: "forecasts.editor.salary.currency_label",
    type: "text",
  },
  {
    name: "person_key",
    labelKey: "forecasts.editor.salary.person_key_label",
    type: "text",
    param: true,
  },
  {
    name: "gross_or_net",
    labelKey: "forecasts.editor.salary.gross_or_net_label",
    type: "select",
    param: true,
    options: [
      {
        value: "gross",
        labelKey: "forecasts.editor.salary.gross_or_net_gross",
      },
      { value: "net", labelKey: "forecasts.editor.salary.gross_or_net_net" },
    ],
  },
  {
    name: "frequency",
    labelKey: "forecasts.editor.salary.frequency_label",
    type: "select",
    param: true,
    options: [
      { value: "annual", labelKey: "forecasts.editor.salary.frequency_annual" },
      {
        value: "monthly",
        labelKey: "forecasts.editor.salary.frequency_monthly",
      },
      {
        value: "biweekly",
        labelKey: "forecasts.editor.salary.frequency_biweekly",
      },
      { value: "weekly", labelKey: "forecasts.editor.salary.frequency_weekly" },
    ],
  },
  {
    name: "growth_policy",
    labelKey: "forecasts.editor.salary.growth_policy_label",
    type: "select",
    param: true,
    options: [
      { value: "flat", labelKey: "forecasts.editor.salary.growth_policy_flat" },
      {
        value: "fixed_rate",
        labelKey: "forecasts.editor.salary.growth_policy_fixed_rate",
      },
    ],
  },
  {
    name: "growth_rate",
    labelKey: "forecasts.editor.salary.growth_rate_label",
    type: "number",
    param: true,
  },
  {
    name: "starts_on",
    labelKey: "forecasts.editor.salary.starts_on_label",
    type: "date",
  },
  {
    name: "ends_on",
    labelKey: "forecasts.editor.salary.ends_on_label",
    type: "date",
  },
];

const FORM_SCHEMAS: Readonly<Record<string, ReadonlyArray<EditorField>>> = {
  salary: SALARY_SCHEMA,
};

// The top-level primary values a field may read by name (everything outside the
// form-specific `params` bag). Narrowed so reads are type-safe without an unsafe
// index-signature cast on `EditorPrimaryValues`.
const PRIMARY_VALUE_READERS: Readonly<
  Record<
    string,
    (values: EditorPrefillReadModel["primary_values"]) => string | null
  >
> = {
  name: (values) => values.name,
  amount: (values) => values.amount,
  currency: (values) => values.currency,
  starts_on: (values) => values.starts_on,
  ends_on: (values) => values.ends_on,
};

// Read a field's current value from the typed prefill (top-level primary value or
// the `params` bag), coerced to a string the input can render.
function fieldValue(
  prefill: EditorPrefillReadModel,
  field: EditorField,
): string {
  const raw = field.param
    ? prefill.primary_values.params[field.name]
    : PRIMARY_VALUE_READERS[field.name]?.(prefill.primary_values);
  if (raw === null || raw === undefined) {
    return "";
  }
  return String(raw);
}

// Localize a stable field error code (`"blank"`, `"not_positive"`, …).
function errorMessage(code: string): string {
  return ft(`forecasts.editor.errors.${code}`);
}

export interface SalaryFormProps {
  /** The loaded typed editor payload for the assumption being edited. */
  readonly prefill: EditorPrefillReadModel;
  /** Field-keyed typed validation errors from a failed save. */
  readonly fieldErrors: EditorFieldErrors;
  /** The top-level summary error code for a failed save, or `null`. */
  readonly summaryError: string | null;
  /** The form element id, so the drawer footer's submit button can target it. */
  readonly formId: string;
  /** Drives the typed PATCH save (owned by the drawer). */
  readonly onSubmit: (event: React.FormEvent<HTMLFormElement>) => void;
  /** Reports that the form has unsaved edits (drives the dirty-state warning). */
  readonly onDirty: () => void;
}

/**
 * Renders the assumption-specific form selected by the prefill's `form_key`. The
 * salary form is the only interactive editor in the MVP; an unknown `form_key`
 * renders a neutral unsupported body rather than guessing a layout.
 */
export default function SalaryForm({
  prefill,
  fieldErrors,
  summaryError,
  formId,
  onSubmit,
  onDirty,
}: SalaryFormProps): JSX.Element {
  const schema = FORM_SCHEMAS[prefill.form_key];

  return (
    <form
      id={formId}
      data-testid="forecast-assumption-editor-form"
      onSubmit={onSubmit}
      onChange={onDirty}
      className="flex flex-col gap-4"
    >
      {summaryError ? (
        <p
          data-testid="forecast-assumption-editor-summary-error"
          role="alert"
          className="rounded-lg border border-warning bg-surface p-3 text-sm text-warning"
        >
          {ft("forecasts.editor.summary_error")}
        </p>
      ) : null}

      {schema === undefined ? (
        <p className="text-sm text-subdued">{prefill.form_key}</p>
      ) : (
        schema.map((field) => {
          const fieldId = `forecast-editor-field-${field.name}`;
          const errorCode = fieldErrors[field.name];
          return (
            <div key={field.name} className="flex flex-col gap-1">
              <label
                htmlFor={fieldId}
                className="text-xs font-medium text-secondary"
              >
                {ft(field.labelKey)}
              </label>
              {field.type === "select" ? (
                <select
                  id={fieldId}
                  name={field.name}
                  data-testid={fieldId}
                  defaultValue={fieldValue(prefill, field)}
                  className="rounded-lg border border-primary bg-container px-3 py-2 text-sm text-primary"
                >
                  {field.options?.map((option) => (
                    <option key={option.value} value={option.value}>
                      {ft(option.labelKey)}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  id={fieldId}
                  name={field.name}
                  type={field.type}
                  data-testid={fieldId}
                  defaultValue={fieldValue(prefill, field)}
                  className={`rounded-lg border border-primary bg-container px-3 py-2 text-sm text-primary ${field.name === "amount" ? "privacy-sensitive" : ""}`}
                />
              )}
              {errorCode ? (
                <p
                  data-testid={`${fieldId}-error`}
                  className="text-xs text-warning"
                >
                  {errorMessage(errorCode)}
                </p>
              ) : null}
            </div>
          );
        })
      )}
    </form>
  );
}
