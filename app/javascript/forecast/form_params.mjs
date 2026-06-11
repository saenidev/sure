// Mirror of the form->engine param seam in
// app/models/forecasts/projection/packet_builder.rb (#engine_policy /
// #fractional_rate / #policy_params): turns raw drawer form values into the
// engine param overrides previewPeriods consumes. Pure ESM, zero imports —
// shared between the importmap pin "forecast/form_params" and the node
// --test suite (test/javascript).

// Ruby's `present?` for form values: null/undefined/whitespace-only are blank.
function isPresent(value) {
  return value != null && String(value).trim() !== "";
}

// PacketBuilder#engine_policy mirror. A hash is already engine-shaped
// (legacy/test shape) and passes through by identity. The form's flat policy
// string maps: "fixed_rate" with a present percentage rate ->
// annual_percentage at the FRACTIONAL rate (the form stores "3.0" == 3%, the
// engine compounds 0.03); anything else (e.g. "flat", blank) -> no growth.
export function enginePolicy(policy, rate) {
  if (policy != null && typeof policy === "object") return policy;
  if (String(policy) === "fixed_rate" && isPresent(rate)) {
    return { type: "annual_percentage", rate: Number(rate) / 100 };
  }
  return { type: "none" };
}

// Maps a plain object of drawer form values (field name -> value, as read
// from the form's assumption[...] inputs) into engine param overrides.
// Only keys PRESENT in `values` produce overrides, so an untouched field
// never clobbers the packet's stored param; blank scalar values (mid-typing)
// are skipped for the same reason. Policy pairs fold through enginePolicy,
// keyed on the policy field's presence — mirroring PacketBuilder
// #policy_params, which normalizes only when the policy key exists.
export function normalizeFormValues(values) {
  const params = {};

  for (const key of ["amount", "frequency", "currency", "net_ratio"]) {
    if (key in values && isPresent(values[key])) params[key] = String(values[key]);
  }
  if ("growth_policy" in values) {
    params.growth_policy = enginePolicy(values.growth_policy, values.growth_rate);
  }
  if ("inflation_policy" in values) {
    params.inflation_policy = enginePolicy(values.inflation_policy, values.inflation_rate);
  }
  return params;
}
