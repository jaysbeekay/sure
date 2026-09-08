import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Three lines on one chart:
//
//   scheduled   the original contract, origination -> maturity
//   projected   where today's balance is actually heading
//   accelerated the same, under a hypothetical regular extra repayment
//
// The last is absent until someone models one. All three coexist when it is
// present, because "where am I heading, and where would I head if I paid more?"
// is a comparison, and it needs both halves on screen.
//
// Series are distinguished by DASH PATTERN as well as colour. Hue alone fails
// in greyscale and under deuteranopia, and red/green would be the worst
// possible pair to rely on.
export default class extends Controller {
  static values = { data: Object };

  connect() {
    this._draw = this._draw.bind(this);
    window.addEventListener("resize", this._draw);
    // The chart mounts inside a tab panel, which can be zero-width on first
    // connect (Turbo restoring a hidden tab). Draw when the box settles.
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(this._draw);
      this._observer.observe(this.element);
    } else {
      this._draw();
    }
    // Colours are read at draw time, so a theme switch while this page is open
    // would otherwise leave the chart painted for the previous theme.
    if (typeof MutationObserver !== "undefined") {
      this._themeObserver = new MutationObserver(this._draw);
      this._themeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-theme", "class"],
      });
    }
  }

  disconnect() {
    window.removeEventListener("resize", this._draw);
    this._observer?.disconnect();
    this._themeObserver?.disconnect();
    this._tooltip?.remove();
  }

  // Design tokens are CSS custom properties. `var(--x)` is NOT substituted in
  // an SVG presentation attribute -- an unresolvable value leaves stroke at its
  // initial `none` and the path renders invisibly, with correct geometry and no
  // error. Resolve to a concrete colour first, and keep the token as the
  // source rather than hardcoding hex.
  _token(name, fallback) {
    const value = getComputedStyle(document.documentElement)
      .getPropertyValue(name)
      .trim();
    return value || fallback;
  }

  _draw() {
    const root = this.element;
    const width = root.clientWidth;
    const height = root.clientHeight;
    if (width <= 0 || height <= 0) return;

    root.innerHTML = "";
    const data = this.dataValue || {};

    // Date-only strings parse as UTC midnight in `new Date`, shifting the day
    // back for anyone west of Greenwich. Parse the components instead.
    const parseDate = (s) => {
      if (!s) return null;
      const [y, m, d] = s.split("-").map(Number);
      return new Date(y, m - 1, d);
    };
    const toPoint = (p) => ({ date: parseDate(p.date), balance: p.balance });

    const scheduled = (data.scheduled || []).map(toPoint);
    const projected = (data.projected || []).map(toPoint);
    const accelerated = (data.accelerated || []).map(toPoint);
    if (scheduled.length < 2) return;

    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const axisColor = isDark ? "#cfcfcf" : "#737373";
    const series = [
      { points: scheduled, key: "scheduled", color: this._token("--color-red-500", "#ef4444"), dash: "6 4", width: 1.5 },
      { points: projected, key: "projected", color: this._token("--color-green-600", "#16a34a"), dash: null, width: 2 },
      { points: accelerated, key: "accelerated", color: this._token("--color-blue-600", "#2563eb"), dash: "2 3", width: 2 },
    ].filter((s) => s.points.length > 1);

    const allPoints = series.flatMap((s) => s.points);
    const x = d3
      .scaleTime()
      .domain(d3.extent(allPoints, (d) => d.date))
      .range([44, width - 12]);
    const y = d3
      .scaleLinear()
      .domain([0, (d3.max(allPoints, (d) => d.balance) || 1) * 1.05])
      .range([height - 24, 8]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr("aria-label", data.aria_description || "");

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    // Axes first, so the series draw over them.
    svg
      .append("g")
      .attr("transform", `translate(0,${height - 24})`)
      .call(d3.axisBottom(x).ticks(Math.max(2, Math.floor(width / 140))).tickSizeOuter(0))
      .call((g) => g.selectAll("text").style("fill", axisColor).style("font-size", "11px"))
      .call((g) => g.selectAll("line,path").style("stroke", axisColor).style("opacity", 0.3));

    svg
      .append("g")
      .attr("transform", "translate(44,0)")
      .call(d3.axisLeft(y).ticks(4).tickFormat(d3.format("~s")).tickSizeOuter(0))
      .call((g) => g.selectAll("text").style("fill", axisColor).style("font-size", "11px"))
      .call((g) => g.selectAll("line,path").style("stroke", axisColor).style("opacity", 0.3));

    const today = parseDate(data.today);
    if (today) {
      svg
        .append("line")
        .attr("x1", x(today))
        .attr("x2", x(today))
        .attr("y1", 8)
        .attr("y2", height - 24)
        .style("stroke", axisColor)
        .style("stroke-dasharray", "2 3")
        .style("opacity", 0.6);
    }

    series.forEach((s) => {
      svg
        .append("path")
        .datum(s.points)
        .attr("d", line)
        // Names the line in the DOM. The series are otherwise distinguishable
        // only by stroke colour, which is exactly what a rendering test must
        // not have to parse to know which line it is looking at.
        .attr("data-series", s.key)
        .style("fill", "none")
        // .style, not .attr: see _token above.
        .style("stroke", s.color)
        .style("stroke-width", s.width)
        .style("stroke-linecap", "round")
        .style("stroke-linejoin", "round")
        .style("stroke-dasharray", s.dash || "none");

      // Interval markers. Thinned to roughly one per 60px so a 360-payment
      // schedule does not become a solid band of circles.
      const step = Math.max(1, Math.ceil(s.points.length / Math.max(2, width / 60)));
      svg
        .append("g")
        .selectAll("circle")
        .data(s.points.filter((_, i) => i % step === 0))
        .join("circle")
        .attr("cx", (d) => x(d.date))
        .attr("cy", (d) => y(d.balance))
        .attr("r", 2.5)
        .style("fill", s.color);
    });

    this._installTooltip(svg, { x, y, series, width, height, data });
  }

  _installTooltip(svg, { x, y, series, width, height, data }) {
    this._tooltip?.remove();
    const tooltip = document.createElement("div");
    tooltip.className =
      "absolute pointer-events-none hidden rounded-md bg-container shadow-border-xs px-2 py-1 text-xs text-primary";
    tooltip.style.position = "absolute";
    this.element.style.position = "relative";
    this.element.appendChild(tooltip);
    this._tooltip = tooltip;

    const bisect = d3.bisector((d) => d.date).left;
    const nearest = (points, date) => {
      if (!points.length) return null;
      const i = bisect(points, date);
      const a = points[Math.max(0, i - 1)];
      const b = points[Math.min(points.length - 1, i)];
      if (!a) return b;
      if (!b) return a;
      return date - a.date <= b.date - date ? a : b;
    };
    const money = (value) =>
      new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: data.currency || "USD",
        maximumFractionDigits: 0,
      }).format(value);

    svg
      .append("rect")
      .attr("x", 44)
      .attr("y", 8)
      .attr("width", Math.max(0, width - 56))
      .attr("height", Math.max(0, height - 32))
      .style("fill", "transparent")
      .on("mousemove", (event) => {
        const [px] = d3.pointer(event);
        const date = x.invert(px);
        const rows = series
          .map((s) => {
            const point = nearest(s.points, date);
            return point ? `${data.labels?.[s.key] || s.key}: ${money(point.balance)}` : null;
          })
          .filter(Boolean);
        if (!rows.length) return;

        // Text nodes, never innerHTML. Nothing here is attacker-controlled
        // today, but a tooltip that builds markup out of interpolated strings
        // is one payload change away from being an injection point.
        tooltip.replaceChildren();
        for (const text of [d3.timeFormat("%b %Y")(date), ...rows]) {
          const div = document.createElement("div");
          div.textContent = text;
          tooltip.appendChild(div);
        }
        tooltip.classList.remove("hidden");
        tooltip.style.left = `${Math.min(px + 12, width - 150)}px`;
        tooltip.style.top = "8px";
      })
      .on("mouseleave", () => tooltip.classList.add("hidden"));
  }
}
