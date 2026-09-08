import { Controller } from "@hotwired/stimulus";

// Add and remove rate-change rows on the loan form.
//
// Rows are plain inputs named as an array, so the form submits and the server
// reads them with no JavaScript at all -- this controller only saves the user
// a round trip per row. A row removed here is removed from the DOM, so it is
// simply absent from the submission; there is no "destroy" flag to keep in
// sync with the server's idea of which rows exist.
export default class extends Controller {
  static targets = ["rows", "template", "empty"];

  add(event) {
    event.preventDefault();

    const row = this.templateTarget.content.firstElementChild.cloneNode(true);
    this.rowsTarget.appendChild(row);
    row.querySelector("input[type='date']")?.focus();
    this.#syncEmptyState();
  }

  remove(event) {
    event.preventDefault();
    event.target.closest("[data-rate-change-row]")?.remove();
    this.#syncEmptyState();
  }

  #syncEmptyState() {
    if (!this.hasEmptyTarget) return;
    this.emptyTarget.hidden = this.rowsTarget.children.length > 0;
  }
}
