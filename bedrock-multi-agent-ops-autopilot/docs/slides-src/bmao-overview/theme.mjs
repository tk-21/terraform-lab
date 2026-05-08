export const theme = {
  bg: "#0b1220",
  panel: "#111a2d",
  panelAlt: "#16243d",
  panelSoft: "#1a2b49",
  text: "#f3f6fb",
  muted: "#9fb0c8",
  accent: "#ffb84d",
  accentSoft: "#ffd89a",
  cyan: "#54d2ff",
  green: "#3ddc97",
  red: "#ff7f87",
  line: "#274264",
};

export function addBackground(ctx, slide) {
  ctx.addShape(slide, {
    left: 0,
    top: 0,
    width: ctx.W,
    height: ctx.H,
    fill: theme.bg,
  });
  ctx.addShape(slide, {
    left: 0,
    top: 0,
    width: ctx.W,
    height: 96,
    fill: "#09101c",
  });
  ctx.addShape(slide, {
    left: 1000,
    top: -120,
    width: 420,
    height: 420,
    geometry: "ellipse",
    fill: "#12345c",
    line: ctx.line("#12345c", 0),
  });
  ctx.addShape(slide, {
    left: 1060,
    top: -60,
    width: 260,
    height: 260,
    geometry: "ellipse",
    fill: "#1f5a8e",
    line: ctx.line("#1f5a8e", 0),
  });
}

export function addHeader(ctx, slide, kicker, title, subtitle) {
  ctx.addText(slide, {
    text: kicker.toUpperCase(),
    left: 64,
    top: 34,
    width: 260,
    height: 24,
    fontSize: 14,
    color: theme.accent,
    bold: true,
    face: ctx.fonts.mono,
  });
  ctx.addText(slide, {
    text: title,
    left: 64,
    top: 62,
    width: 820,
    height: 50,
    fontSize: 28,
    color: theme.text,
    bold: true,
    face: ctx.fonts.title,
  });
  if (subtitle) {
    ctx.addText(slide, {
      text: subtitle,
      left: 64,
      top: 110,
      width: 760,
      height: 40,
      fontSize: 13,
      color: theme.muted,
    });
  }
}

export function addFooter(ctx, slide, label = "bedrock-multi-agent-ops-autopilot") {
  ctx.addText(slide, {
    text: `${label}  |  slide ${String(ctx.slideNumber).padStart(2, "0")}`,
    left: 64,
    top: 686,
    width: 520,
    height: 18,
    fontSize: 10,
    color: "#7e91af",
    face: ctx.fonts.mono,
  });
}

export function addPanel(ctx, slide, { left, top, width, height, title, subtitle, fill = theme.panel }) {
  ctx.addShape(slide, {
    left,
    top,
    width,
    height,
    geometry: "roundRect",
    fill,
    line: ctx.line(theme.line, 1),
  });
  if (title) {
    ctx.addText(slide, {
      text: title,
      left: left + 18,
      top: top + 16,
      width: width - 36,
      height: 22,
      fontSize: 16,
      color: theme.text,
      bold: true,
    });
  }
  if (subtitle) {
    ctx.addText(slide, {
      text: subtitle,
      left: left + 18,
      top: top + 40,
      width: width - 36,
      height: 28,
      fontSize: 11,
      color: theme.muted,
    });
  }
}

export function addBullets(ctx, slide, { items, left, top, width, lineHeight = 28, fontSize = 16, color = theme.text }) {
  items.forEach((item, index) => {
    ctx.addShape(slide, {
      left,
      top: top + index * lineHeight + 7,
      width: 8,
      height: 8,
      geometry: "ellipse",
      fill: theme.accent,
      line: ctx.line(theme.accent, 0),
    });
    ctx.addText(slide, {
      text: item,
      left: left + 18,
      top: top + index * lineHeight,
      width: width - 18,
      height: lineHeight,
      fontSize,
      color,
    });
  });
}

export function addMetricCard(ctx, slide, { left, top, width, height, value, label, accent = theme.cyan }) {
  ctx.addShape(slide, {
    left,
    top,
    width,
    height,
    geometry: "roundRect",
    fill: theme.panelAlt,
    line: ctx.line(theme.line, 1),
  });
  ctx.addText(slide, {
    text: value,
    left: left + 16,
    top: top + 12,
    width: width - 24,
    height: 30,
    fontSize: 28,
    color: accent,
    bold: true,
    face: ctx.fonts.title,
  });
  ctx.addText(slide, {
    text: label,
    left: left + 16,
    top: top + 48,
    width: width - 24,
    height: 26,
    fontSize: 12,
    color: theme.muted,
  });
}

export function addConnector(ctx, slide, { left, top, width, height = 4, fill = theme.cyan }) {
  ctx.addShape(slide, {
    left,
    top,
    width,
    height,
    fill,
    line: ctx.line(fill, 0),
  });
}
