import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Grouped bar chart used by the dashboard "money flow" widget — each month
// shows an expense bar (red) and an income bar (green) side by side.
// Modeled after time_series_chart_controller's lifecycle (install/teardown,
// ResizeObserver, turbo:load reinstall, page-relative tooltip positioning)
// but with scaleBand/scaleLinear instead of a line.

// Breathing room between neighbouring month labels before they read as touching.
const LABEL_GAP_PX = 8;

// The palettes a caller may choose, by name. Deliberately a fixed map rather
// than two colour values passed in: a colour that arrives as a Stimulus value
// is attribute-sourced text, and writing it into .style() or .attr("fill")
// hands external data to a style sink. Naming a palette instead means the only
// strings that ever reach those sinks are the literals below.
//
// "flow" is what the money-flow widget has always rendered — expenses gray,
// not destructive red — and is the default, so that caller passes nothing.
const PALETTES = {
  flow: { positive: "var(--color-success)", negative: "var(--color-gray-400)" },
  profit: { positive: "var(--color-success)", negative: "var(--color-destructive)" },
};
const DEFAULT_PALETTE = "flow";

export default class extends Controller {
  // The two series are named on the wire so a chart that is not about income
  // and expenses does not have to lie in its payload. Every value defaults to
  // what the money-flow widget already passes, so that caller is unchanged.
  static values = {
    data: Array,
    currency: { type: String, default: "USD" },
    incomeLabel: { type: String, default: "Income" },
    expenseLabel: { type: String, default: "Expenses" },
    positiveKey: { type: String, default: "income" },
    negativeKey: { type: String, default: "expense" },
    palette: { type: String, default: DEFAULT_PALETTE },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("*").remove();
  }

  _install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const data = this.dataValue || [];

    if (width < 50 || height < 50 || data.length === 0) return;

    const margin = { top: 16, right: 4, bottom: 24, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const series = [this.positiveKeyValue, this.negativeKeyValue];
    const seriesColor = {
      [this.positiveKeyValue]: this._palette().positive,
      [this.negativeKeyValue]: this._palette().negative,
    };

    const x0 = d3
      .scaleBand()
      .domain(data.map((d) => d.label))
      .range([0, innerWidth])
      .padding(0.3);

    const x1 = d3.scaleBand().domain(series).range([0, x0.bandwidth()]).padding(0.15);

    const maxValue = d3.max(data, (d) => Math.max(...series.map((key) => d[key] ?? 0))) || 1;
    const y = d3.scaleLinear().domain([0, maxValue * 1.1]).range([innerHeight, 0]);
    // Floor tiny-but-nonzero bars (e.g. an in-progress month) at 2px so they stay visible.
    const barHeight = (v) => (v > 0 ? Math.max(2, innerHeight - y(v)) : 0);

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const showTooltip = (event, month, key) => {
      const estimatedTooltipWidth = 200;
      const pageWidth = document.body.clientWidth;
      const tooltipX = event.pageX + 10;
      const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
      const adjustedX = overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

      this._renderTooltip(tooltip, month, key);
      tooltip
        .style("opacity", 1)
        .style("left", `${adjustedX}px`)
        .style("top", `${event.pageY - 10}px`);
    };

    const hideTooltip = () => tooltip.style("opacity", 0);

    const monthGroups = group
      .selectAll("g.month")
      .data(data)
      .join("g")
      .attr("class", "month")
      .attr("transform", (d) => `translate(${x0(d.label)},0)`);

    monthGroups
      .selectAll("rect")
      .data((d) => series.map((key) => ({ key, value: d[key], month: d })))
      .join("rect")
      .attr("x", (d) => x1(d.key))
      .attr("y", (d) => innerHeight - barHeight(d.value))
      .attr("width", x1.bandwidth())
      .attr("height", (d) => barHeight(d.value))
      .attr("rx", 3)
      .attr("fill", (d) => seriesColor[d.key])
      // In-progress month (period capped at today) reads as provisional.
      .attr("fill-opacity", (d) => (d.month.partial ? 0.5 : 1))
      .on("mousemove", (event, d) => showTooltip(event, d.month, d.key))
      .on("mouseleave", hideTooltip);

    const axisLabels = group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", (_d, i) => (data[i].highlighted ? "text-primary fill-current" : "text-secondary fill-current"))
      .style("font-size", "12px")
      .style("font-weight", (_d, i) => (data[i].highlighted ? 600 : 500));

    this._fitAxisLabels(axisLabels, data, x0.step());
  }

  // The month labels are sized by the locale, not by the chart: "Mar 2026" fits
  // a phone, "Mar de 2026" (ca/es/pt) does not and overlaps its neighbours.
  // Measure what actually rendered and step down until it fits — full label,
  // then the abbreviated month, then every other tick. Measuring beats guessing
  // at a character width, which varies by locale, font and zoom.
  _fitAxisLabels(labels, data, step) {
    if (labels.empty()) return;

    const widest = () => d3.max(labels.nodes(), (node) => node.getComputedTextLength()) || 0;
    const fits = () => widest() <= step - LABEL_GAP_PX;

    if (fits()) return;

    labels.text((_d, i) => data[i].short_label ?? data[i].label);
    if (fits()) return;

    // Still too wide (a very narrow column): thin out rather than overlap.
    // The parity is taken from the highlighted month rather than fixed at even,
    // so that month survives without being an exception to the pattern — it
    // sits last (build_money_flow_data counts down to the selected month), and
    // keeping it on top of every even index left the final two labels one step
    // apart, the very spacing that had just been measured as too tight.
    const highlightedIndex = data.findIndex((d) => d.highlighted);
    const keepParity = highlightedIndex >= 0 ? highlightedIndex % 2 : 0;
    labels.style("display", (_d, i) => (i % 2 === keepParity ? null : "none"));
  }

  // An unknown name falls back to the default rather than rendering colourless
  // bars, so a typo in a template degrades to the money-flow palette.
  _palette() {
    return PALETTES[this.paletteValue] ?? PALETTES[DEFAULT_PALETTE];
  }

  _colorFor(key) {
    const palette = this._palette();
    return key === this.positiveKeyValue ? palette.positive : palette.negative;
  }

  // Built as DOM rather than returned as a string for .html() to parse.
  //
  // Three of the four values here reach the page from outside this method —
  // the series labels and the colours are Stimulus values, so they arrive as
  // DOM attributes, and month.label is server-rendered — and .html() parses
  // whatever it is handed. Class names are the only literals, so they are the
  // only things set as markup: .text() assigns textContent and .style()
  // assigns through the CSSOM, and neither parses.
  _renderTooltip(tooltip, month, key) {
    const label = key === this.positiveKeyValue ? this.incomeLabelValue : this.expenseLabelValue;

    tooltip.selectAll("*").remove();
    tooltip.append("div").attr("class", "text-xs text-secondary mb-1").text(month.label);

    const row = tooltip
      .append("div")
      .attr("class", "flex items-center gap-1.5 text-primary font-medium tabular-nums");

    row
      .append("span")
      .attr("class", "inline-block w-2 h-2 rounded-full")
      .style("background-color", this._colorFor(key));

    row.append("span").text(`${label}: ${this._formatCurrency(month[key])}`);
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return value;
    }
  }
}
