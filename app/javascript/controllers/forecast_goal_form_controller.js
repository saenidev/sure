import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="forecast-goal-form"
//
// Drives the goal-type-conditional fields on the forecast goal form. Each
// optional field group declares which goal types it applies to via a
// `data-forecast-goal-form-types` token list (space-separated). On goal-type
// change (and on connect) the controller shows only the groups whose token list
// includes the selected goal type, and toggles `disabled` on the inputs inside
// hidden groups so they neither submit stale values nor trip native
// required-validation while hidden.
//
// This mirrors the model's `target_fields_match_goal_type` validation: runway
// goals require target_duration_days, amount goals require target_amount. The
// server-side validation remains the source of truth; this only declutters the
// form. Everything is declarative and server-rendered; no request is made here.
export default class extends Controller {
  static targets = ["goalType", "field"];

  connect() {
    this.refresh();
  }

  refresh() {
    const goalType = this.goalTypeTarget.value;

    this.fieldTargets.forEach((group) => {
      const applies = (group.dataset.forecastGoalFormTypes || "")
        .split(/\s+/)
        .filter(Boolean);
      const visible = applies.includes(goalType);
      group.classList.toggle("hidden", !visible);
      this.setDisabled(group, !visible);
    });
  }

  setDisabled(container, disabled) {
    container
      .querySelectorAll("input, select, textarea")
      .forEach((input) => {
        input.disabled = disabled;
      });
  }
}
