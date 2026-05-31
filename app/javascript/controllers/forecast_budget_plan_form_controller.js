import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["amount", "slider"];

  syncAmount(event) {
    const slider = event.currentTarget;
    const amount = this.amountTargetFor(slider.dataset.rowKey);
    if (!amount) return;

    amount.value = slider.value;
  }

  syncSlider(event) {
    const amount = event.currentTarget;
    const slider = this.sliderTargetFor(amount.dataset.rowKey);
    if (!slider) return;

    const value = Number(amount.value || 0);
    const max = Number(slider.max || 0);
    if (value > max) slider.max = String(Math.ceil(value * 1.5));
    slider.value = amount.value || 0;
  }

  amountTargetFor(rowKey) {
    return this.amountTargets.find(
      (target) => target.dataset.rowKey === rowKey,
    );
  }

  sliderTargetFor(rowKey) {
    return this.sliderTargets.find(
      (target) => target.dataset.rowKey === rowKey,
    );
  }
}
