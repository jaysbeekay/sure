import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// The loan balance chart: three series on one axis.
//
//   actual     the recorded balance, origination -> today. Solid: fact.
//   scheduled  the original contract, origination -> maturity. Dashed.
//   projected  where today's balance is heading on the contract's repayment.
//              Dashed.
//
// Series are distinguished by DASH PATTERN as well as colour. Hue alone fails
// in greyscale and under deuteranopia, and red/green would be the worst
// possible pair to rely on. Solid-versus-dashed also keeps "recorded fact"
// and "forecast" visually separable.
//
// The x-domain comes from the payload, not from the data: the period picker
// governs it (#100, decision 4). Series are drawn through a clip so a line
// that leaves the window is cut at its edge rather than stretching the axis.

// Date-only strings parse as UTC midnight in `new Date`, shifting the day
// back for anyone west of Greenwich. Parse the components instead.
const parseDate = (s) => {
  if (!s) return null;
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
};

export default class extends Controller {
  static values = { data: Object, tableId: String };

  connect() {
    this._draw = this._draw.bind(this);
    window.addEventListener("resize", this._draw);
    // The container can be zero-width on first connect (a Turbo restore, a
    // hidden parent). Draw when the box settles.
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

  // Design tokens are CSS custom properties. Resolved to a concrete colour at
  // draw time and applied with .style(), keeping the token as the source.
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

    const toPoint = (p) => ({ date: parseDate(p.date), balance: p.balance });

    const domainStart = parseDate(data.domain_start);
    const domainEnd = parseDate(data.domain_end);
    const today = parseDate(data.today);
    if (!domainStart || !domainEnd || domainEnd <= domainStart) return;

    const success = this._token("--color-success", "#15803d");
    const destructive = this._token("--color-destructive", "#ef4444");
    const muted = this._token("--color-gray-400", "#9ca3af");

    // Drawing order: forecasts underneath, fact on top.
    const series = [
      {
        key: "scheduled",
        points: (data.scheduled || []).map(toPoint),
        color: destructive,
        dash: "6 4",
        width: 1.5,
      },
      {
        key: "projected",
        points: (data.projected || []).map(toPoint),
        color: success,
        dash: "4 4",
        width: 2,
      },
      {
        key: "actual",
        points: (data.actual || []).map(toPoint),
        color: success,
        dash: null,
        width: 2,
      },
    ].filter((s) => s.points.length > 1);
    if (series.length === 0) return;

    const margin = { top: 12, right: 12, bottom: 24, left: 48 };
    const x = d3
      .scaleTime()
      .domain([domainStart, domainEnd])
      .range([margin.left, width - margin.right]);
    // Scale the y-axis to what is inside the window plus each line's first
    // point either side of it, so a line crossing the window fits without the
    // window being sized for points it never shows.
    const inWindow = (points) => {
      const inside = points.filter(
        (p) => p.date >= domainStart && p.date <= domainEnd,
      );
      const before = points.filter((p) => p.date < domainStart).at(-1);
      const after = points.find((p) => p.date > domainEnd);
      return [before, ...inside, after].filter(Boolean);
    };
    const scalePoints = series.flatMap((s) => inWindow(s.points));
    const yMax = (d3.max(scalePoints, (d) => d.balance) || 1) * 1.05;
    const y = d3
      .scaleLinear()
      .domain([0, yMax])
      .range([height - margin.bottom, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr("aria-label", data.aria_description || "");
    if (this.hasTableIdValue && this.tableIdValue) {
      svg.attr("aria-describedby", this.tableIdValue);
    }

    const id = `loan-chart-${Math.random().toString(36).slice(2, 8)}`;
    const defs = svg.append("defs");
    const plotClip = `${id}-plot`;
    defs
      .append("clipPath")
      .attr("id", plotClip)
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", Math.max(0, width - margin.left - margin.right))
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    // The hover split on the actual series: the recorded line stays coloured up
    // to the cursor and greys past it. Two clips share one edge, moved on
    // pointer events; at rest the edge sits at the window's end and the whole
    // line is coloured. Forecasts have no "before the cursor" to speak of.
    const splitAt = (px) => {
      pastClip.attr("width", Math.max(0, px - margin.left));
      futureClip
        .attr("x", px)
        .attr("width", Math.max(0, width - margin.right - px));
    };
    const pastClip = defs
      .append("clipPath")
      .attr("id", `${id}-past`)
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    const futureClip = defs
      .append("clipPath")
      .attr("id", `${id}-future`)
      .append("rect")
      .attr("y", margin.top)
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    splitAt(width - margin.right);

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.balance))
      .curve(d3.curveMonotoneX);
    const area = d3
      .area()
      .x((d) => x(d.date))
      .y0(height - margin.bottom)
      .y1((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    // Axes first, so the series draw over them. Text in currentColor: the
    // container carries the text token, so the axis follows the theme.
    svg
      .append("g")
      .attr("transform", `translate(0,${height - margin.bottom})`)
      .call(
        d3
          .axisBottom(x)
          .ticks(Math.max(2, Math.floor(width / 140)))
          .tickSizeOuter(0),
      )
      .call((g) =>
        g
          .selectAll("text")
          .style("fill", "currentColor")
          .style("opacity", 0.7)
          .style("font-size", "11px"),
      )
      .call((g) =>
        g
          .selectAll("line,path")
          .style("stroke", "currentColor")
          .style("opacity", 0.2),
      );
    svg
      .append("g")
      .attr("transform", `translate(${margin.left},0)`)
      .call(
        d3.axisLeft(y).ticks(4).tickFormat(d3.format("~s")).tickSizeOuter(0),
      )
      .call((g) =>
        g
          .selectAll("text")
          .style("fill", "currentColor")
          .style("opacity", 0.7)
          .style("font-size", "11px"),
      )
      .call((g) =>
        g
          .selectAll("line,path")
          .style("stroke", "currentColor")
          .style("opacity", 0.2),
      );

    const stroke = (path, s, color) =>
      path
        .style("fill", "none")
        .style("stroke", color)
        .style("stroke-width", s.width)
        .style("stroke-linecap", "round")
        .style("stroke-linejoin", "round")
        .style("stroke-dasharray", s.dash || "none");

    for (const s of series) {
      if (s.key === "actual") {
        svg
          .append("path")
          .datum(s.points)
          .attr("d", area)
          .attr("clip-path", `url(#${plotClip})`)
          .style("fill", s.color)
          .style("opacity", 0.08);
        // The greyed remainder sits underneath; the coloured line on top is
        // the one that carries data-series, so a test asking for the actual
        // line finds the line that is meant to be seen.
        stroke(svg.append("path").datum(s.points).attr("d", line), s, muted)
          .attr("clip-path", `url(#${id}-future)`)
          .attr("data-series-shadow", s.key)
          .style("opacity", 0.6);
        stroke(svg.append("path").datum(s.points).attr("d", line), s, s.color)
          .attr("clip-path", `url(#${id}-past)`)
          .attr("data-series", s.key);
      } else {
        stroke(svg.append("path").datum(s.points).attr("d", line), s, s.color)
          .attr("clip-path", `url(#${plotClip})`)
          .attr("data-series", s.key);
      }

      // Interval markers, thinned to roughly one per 60px so a 360-payment
      // schedule does not become a solid band of circles. Not the accessible
      // signal: dash pattern is.
      const step = Math.max(
        1,
        Math.ceil(s.points.length / Math.max(2, width / 60)),
      );
      svg
        .append("g")
        .attr("clip-path", `url(#${plotClip})`)
        .selectAll("circle")
        .data(s.points.filter((_, i) => i % step === 0))
        .join("circle")
        .attr("cx", (d) => x(d.date))
        .attr("cy", (d) => y(d.balance))
        .attr("r", 2.5)
        .style("fill", s.color);
    }

    if (today && today >= domainStart && today <= domainEnd) {
      svg
        .append("line")
        .attr("x1", x(today))
        .attr("x2", x(today))
        .attr("y1", margin.top)
        .attr("y2", height - margin.bottom)
        .style("stroke", "currentColor")
        .style("stroke-dasharray", "2 3")
        .style("opacity", 0.4);
    }

    this._installInteraction(svg, {
      x,
      series,
      width,
      height,
      margin,
      data,
      domainStart,
      domainEnd,
      splitAt,
    });
  }

  _installInteraction(
    svg,
    { x, series, width, height, margin, data, domainStart, domainEnd, splitAt },
  ) {
    this._tooltip?.remove();
    const tooltip = document.createElement("div");
    tooltip.className =
      "absolute pointer-events-none hidden rounded-md bg-container shadow-border-xs px-2 py-1 text-xs text-primary";
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

    const showAt = (date) => {
      const px = x(date);
      const rows = series
        .map((s) => {
          // A series says nothing about dates outside its own span.
          if (date < s.points[0].date || date > s.points.at(-1).date)
            return null;
          const point = nearest(s.points, date);
          return point
            ? `${data.labels?.[s.key] || s.key}: ${money(point.balance)}`
            : null;
        })
        .filter(Boolean);
      if (!rows.length) return;

      // Text nodes, never innerHTML.
      tooltip.replaceChildren();
      for (const text of [d3.timeFormat("%b %Y")(date), ...rows]) {
        const div = document.createElement("div");
        div.textContent = text;
        tooltip.appendChild(div);
      }
      tooltip.classList.remove("hidden");
      tooltip.style.left = `${Math.min(px + 12, width - 150)}px`;
      tooltip.style.top = `${margin.top}px`;
      splitAt(Math.max(margin.left, Math.min(px, width - margin.right)));
    };
    // The live region announces only what the keyboard asks for. Under a
    // pointer the tooltip rewrites on every movement, and a live region that
    // announces every one of those is noise for anyone using a pointer with a
    // screen reader (#57).
    const announce = (on) => {
      if (on) {
        tooltip.setAttribute("role", "status");
        tooltip.setAttribute("aria-live", "polite");
      } else {
        tooltip.removeAttribute("role");
        tooltip.removeAttribute("aria-live");
      }
    };

    const hide = () => {
      tooltip.classList.add("hidden");
      announce(false);
      splitAt(width - margin.right);
    };

    svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", Math.max(0, width - margin.left - margin.right))
      .attr("height", Math.max(0, height - margin.top - margin.bottom))
      .style("fill", "transparent")
      .style("cursor", "crosshair")
      .on("pointermove", (event) => {
        announce(false);
        const [px] = d3.pointer(event);
        showAt(x.invert(px));
      })
      .on("pointerleave", hide);

    // Keyboard traversal: the same nearest-point data a hover shows, stepped
    // through the dates the data table lists -- one per scheduled payment in
    // the window -- so the keyboard and the table give the same figures (G6).
    // The recorded line's own points are weekly and would otherwise repeat
    // the same month several times over. Arrow keys move, Home/End jump,
    // Escape clears.
    const rowDates = (data.rows || [])
      .map((row) => parseDate(row.date))
      .filter((date) => date && date >= domainStart && date <= domainEnd);
    const stops = Array.from(
      new Set(
        (rowDates.length
          ? rowDates
          : series.flatMap((s) => s.points).map((p) => p.date)
        )
          .filter((date) => date >= domainStart && date <= domainEnd)
          .map((date) => date.getTime()),
      ),
    )
      .sort((a, b) => a - b)
      .map((t) => new Date(t));
    if (!stops.length) return;

    svg.attr("tabindex", 0);
    let focused = null;
    svg.on("keydown", (event) => {
      if (
        !["ArrowLeft", "ArrowRight", "Home", "End", "Escape"].includes(
          event.key,
        )
      )
        return;
      event.preventDefault();
      if (event.key === "Escape") {
        focused = null;
        hide();
        return;
      }
      if (focused === null)
        focused = event.key === "ArrowLeft" ? stops.length - 1 : 0;
      else if (event.key === "ArrowLeft") focused = Math.max(0, focused - 1);
      else if (event.key === "ArrowRight")
        focused = Math.min(stops.length - 1, focused + 1);
      else if (event.key === "Home") focused = 0;
      else focused = stops.length - 1;
      announce(true);
      showAt(stops[focused]);
    });
    svg.on("blur", () => {
      focused = null;
      hide();
    });
  }
}
