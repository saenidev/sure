import { Controller } from "@hotwired/stimulus";

// Opens the inline "Compare scenarios" dialog (a native <dialog>) on demand.
//
// The compose form lives inline on the comparison tab rather than behind a
// turbo-frame fetch (the slice reuses runs#create without a new route), so the
// dialog must not auto-open. This controller wires the trigger button to the
// dialog's native showModal(), keeping the disclosure keyboard- and
// screen-reader-friendly (the <dialog> handles focus + Esc itself).
//
// Connects to data-controller="forecast-compare"
export default class extends Controller {
  static targets = ["dialog"];

  open() {
    if (this.hasDialogTarget && typeof this.dialogTarget.showModal === "function") {
      this.dialogTarget.showModal();
    }
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) {
      this.dialogTarget.close();
    }
  }
}
