import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="forecast-event-form"
//
// Drives the effect-type-conditional fields on the forecast event form. Each
// optional field group declares which effect types it applies to via a
// `data-forecast-event-form-fields` token list (space-separated). On
// effect-type change (and on connect) the controller shows only the groups
// whose token list includes the selected effect type, and toggles `disabled`
// on the inputs inside hidden groups so they neither submit stale values nor
// trip native required-validation while hidden.
//
// The recurrence toggle is independent: a checkbox reveals the recurrence rule
// builder and switches the date label between one-time and recurring. The
// monthly day-of-month field is itself conditional on the chosen frequency.
//
// Everything is declarative and server-rendered; no request is made here.
export default class extends Controller {
  static targets = [
    "effectType",
    "field",
    "recurringToggle",
    "recurrence",
    "frequency",
    "monthlyField",
    "endsOn",
  ];

  connect() {
    this.refreshEffectType();
    this.refreshRecurrence();
  }

  refreshEffectType() {
    const effectType = this.effectTypeTarget.value;

    this.fieldTargets.forEach((group) => {
      const applies = (group.dataset.forecastEventFormFields || "")
        .split(/\s+/)
        .filter(Boolean);
      const visible = applies.includes(effectType);
      group.classList.toggle("hidden", !visible);
      this.setDisabled(group, !visible);
    });
  }

  refreshRecurrence() {
    if (!this.hasRecurrenceTarget || !this.hasRecurringToggleTarget) return;

    const recurring = this.recurringToggleTarget.checked;
    this.recurrenceTarget.classList.toggle("hidden", !recurring);
    this.setDisabled(this.recurrenceTarget, !recurring);

    if (this.hasEndsOnTarget) {
      // ends_on only makes sense for a recurring series.
      this.endsOnTarget.classList.toggle("hidden", !recurring);
      this.setDisabled(this.endsOnTarget, !recurring);
    }

    if (recurring) this.refreshFrequency();
  }

  refreshFrequency() {
    if (!this.hasFrequencyTarget || !this.hasMonthlyFieldTarget) return;

    const monthly = this.frequencyTarget.value === "monthly";
    this.monthlyFieldTarget.classList.toggle("hidden", !monthly);
    this.setDisabled(this.monthlyFieldTarget, !monthly);
  }

  setDisabled(container, disabled) {
    container
      .querySelectorAll("input, select, textarea")
      .forEach((input) => {
        input.disabled = disabled;
      });
  }
}
