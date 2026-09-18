import { describe, it } from "node:test";
import assert from "node:assert/strict";

// Inlined rather than imported, as the other tests in this directory are: the
// controller is an ESM class with d3 imports and there is no bundler here.
// Must be kept in sync with the two extractors in
// app/javascript/controllers/time_series_chart_controller.js.
const extractNumericValue = (numeric) => {
  if (numeric === null || numeric === undefined) return Number.NaN;

  if (typeof numeric === "object" && "amount" in numeric) {
    return Number(numeric.amount);
  }
  return Number(numeric);
};

const extractFormattedValue = (numeric) => {
  if (numeric === null || numeric === undefined) return "";

  if (typeof numeric === "object" && "formatted" in numeric) {
    return numeric.formatted;
  }
  return numeric;
};

describe("time series chart value extraction", () => {
  // `Number(null)` is 0, so without the guard a gap in a series plots on the
  // axis as a real zero and compares as one -- a crash to nothing.
  it("reads a missing numeric value as NaN, never as zero", () => {
    assert.ok(Number.isNaN(extractNumericValue(null)));
    assert.ok(Number.isNaN(extractNumericValue(undefined)));
    assert.equal(extractNumericValue(0), 0);
    assert.equal(extractNumericValue({ amount: "12.5" }), 12.5);
    assert.equal(extractNumericValue("7"), 7);
  });

  // `typeof null` is "object", so `"formatted" in null` throws a TypeError
  // rather than returning false. The two helpers read the same datum, so they
  // have to agree about what it can hold.
  it("reads a missing formatted value without throwing", () => {
    assert.equal(extractFormattedValue(null), "");
    assert.equal(extractFormattedValue(undefined), "");
    assert.equal(extractFormattedValue({ formatted: "$12.50" }), "$12.50");
    assert.equal(extractFormattedValue("12.5"), "12.5");
  });
});
