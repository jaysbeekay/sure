import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="row-expander"
//
// Reveals a table row that belongs to another row: the per-account positions
// under a consolidated holding on the portfolio hub. A <details> element
// cannot live inside a <table>, so this is the smallest declarative stand-in:
// one button in the summary row toggles the `hidden` attribute on the detail
// row and mirrors the state in aria-expanded. Nothing is persisted.
export default class extends Controller {
  static targets = ["row", "chevron"];

  toggle(event) {
    const expanded = this.rowTarget.hidden;
    this.rowTarget.hidden = !expanded;
    event.currentTarget.setAttribute("aria-expanded", String(expanded));
    if (this.hasChevronTarget) {
      this.chevronTarget.classList.toggle("rotate-90", expanded);
    }
  }
}
