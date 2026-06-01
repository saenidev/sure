import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "amount",
    "incomeTotal",
    "mode",
    "netTotal",
    "slider",
    "spendingTotal",
  ];
  static values = { currency: String };

  connect() {
    this.refreshTotals();
  }

  syncAmount(event) {
    const slider = event.currentTarget;
    const amount = this.amountTargetFor(slider.dataset.rowKey);
    if (!amount) return;

    amount.value = slider.value;
    this.updateRowMode(amount);
    this.refreshTotals();
  }

  syncSlider(event) {
    const amount = event.currentTarget;
    const slider = this.sliderTargetFor(amount.dataset.rowKey);
    if (!slider) return;

    const value = Number(amount.value || 0);
    const max = Number(slider.max || 0);
    if (value > max) slider.max = String(Math.ceil(value * 1.5));
    slider.value = amount.value || 0;
    this.updateRowMode(amount);
    this.refreshTotals();
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

  modeTargetFor(rowKey) {
    return this.modeTargets.find((target) => target.dataset.rowKey === rowKey);
  }

  updateRowMode(amount) {
    const mode = this.modeTargetFor(amount.dataset.rowKey);
    if (!mode) return;

    const originalMode = mode.dataset.originalMode || "inherited";
    const originalAmount = Number(amount.dataset.originalAmount || 0);
    const currentAmount = Number(amount.value || 0);

    mode.value =
      originalMode !== "exact" && currentAmount === originalAmount
        ? originalMode
        : "exact";
  }

  refreshTotals() {
    if (
      !this.hasIncomeTotalTarget ||
      !this.hasSpendingTotalTarget ||
      !this.hasNetTotalTarget
    ) {
      return;
    }

    const totals = this.amountTargets.reduce(
      (memo, amount) => {
        const value = Number(amount.value || 0);
        if (amount.dataset.amountType === "expected_income") {
          memo.income += value;
        } else {
          memo.spending += value;
        }
        return memo;
      },
      { income: 0, spending: 0 },
    );

    this.incomeTotalTarget.textContent = this.formatMoney(totals.income);
    this.spendingTotalTarget.textContent = this.formatMoney(totals.spending);
    this.netTotalTarget.textContent = this.formatMoney(
      totals.income - totals.spending,
    );
  }

  formatMoney(value) {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: this.currencyValue || "USD",
      maximumFractionDigits: 0,
    }).format(value);
  }
}
