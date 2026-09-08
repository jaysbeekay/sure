import { Controller } from "@hotwired/stimulus";

// Add and remove rate-change rows, and show the section only for a loan whose
// rate can actually move.
//
// Rows are plain inputs named as an array, so the form submits and the server
// reads them with no JavaScript at all — this controller saves a round trip
// per row and keeps the section honest about whether it applies.
//
// Hidden means DISABLED, not merely invisible. A disabled input is not
// submitted, so a fixed-rate loan sends no `rate_changes` key at all and its
// recorded changes are retained rather than cleared — switching a loan to
// fixed and back does not lose them.
export default class extends Controller {
  static targets = ["rows", "template", "empty", "section", "rateType"];
  static values = { variableTypes: Array };

  connect() {
    this.toggle();
  }

  add(event) {
    event.preventDefault();
    const row = this.templateTarget.content.firstElementChild.cloneNode(true);
    this.rowsTarget.appendChild(row);
    row.querySelector("input[type='date']")?.focus();
    this.#sync();
  }

  remove(event) {
    event.preventDefault();
    event.target.closest("[data-rate-change-row]")?.remove();
    this.#sync();
  }

  toggle() {
    const applies = this.variableTypesValue.includes(this.rateTypeTarget?.value);
    this.sectionTarget.hidden = !applies;
    for (const el of this.sectionTarget.querySelectorAll("input, select, button")) {
      el.disabled = !applies;
    }
    this.#sync();
  }

  #sync() {
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = this.rowsTarget.children.length > 0;
    }
  }
}
