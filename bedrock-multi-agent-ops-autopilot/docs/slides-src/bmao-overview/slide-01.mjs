import { theme, addBackground, addFooter, addMetricCard } from "./theme.mjs";

export function slide01(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);

  ctx.addText(slide, {
    text: "PROJECT OVERVIEW",
    left: 64,
    top: 118,
    width: 240,
    height: 22,
    fontSize: 16,
    color: theme.accent,
    bold: true,
    face: ctx.fonts.mono,
  });
  ctx.addText(slide, {
    text: "Bedrock Multi-Agent Ops Autopilot",
    left: 64,
    top: 148,
    width: 700,
    height: 66,
    fontSize: 34,
    color: theme.text,
    bold: true,
    face: ctx.fonts.title,
  });
  ctx.addText(slide, {
    text: "AWS運用イベントを起点に、Supervisor Agent が Sub-agent へ委譲し、調査・提案・承認付き修復・レポート通知までをつなぐ PoC / ポートフォリオ実装。",
    left: 64,
    top: 226,
    width: 760,
    height: 64,
    fontSize: 18,
    color: theme.muted,
  });

  ctx.addShape(slide, {
    left: 64,
    top: 316,
    width: 520,
    height: 268,
    geometry: "roundRect",
    fill: theme.panel,
    line: ctx.line(theme.line, 1),
  });
  ctx.addText(slide, {
    text: "このデッキで分かること",
    left: 88,
    top: 342,
    width: 280,
    height: 24,
    fontSize: 18,
    color: theme.text,
    bold: true,
  });

  [
    "なぜこの構成が必要なのか",
    "Terraform / Bedrock / Lambda がどう接続されるか",
    "障害系とコスト系のフローがどこで分岐するか",
    "安全設計と現状の実装ギャップは何か",
    "コードをどの順で読めば最短で理解できるか",
  ].forEach((item, index) => {
    ctx.addShape(slide, {
      left: 90,
      top: 384 + index * 36,
      width: 8,
      height: 8,
      geometry: "ellipse",
      fill: index === 3 ? theme.red : theme.accent,
      line: ctx.line(index === 3 ? theme.red : theme.accent, 0),
    });
    ctx.addText(slide, {
      text: item,
      left: 108,
      top: 376 + index * 36,
      width: 430,
      height: 24,
      fontSize: 16,
      color: theme.text,
    });
  });

  addMetricCard(ctx, slide, { left: 642, top: 330, width: 130, height: 92, value: "4", label: "Sub-agents", accent: theme.accent });
  addMetricCard(ctx, slide, { left: 790, top: 330, width: 130, height: 92, value: "4", label: "Action Lambdas", accent: theme.cyan });
  addMetricCard(ctx, slide, { left: 938, top: 330, width: 130, height: 92, value: "2", label: "Event sources", accent: theme.green });
  addMetricCard(ctx, slide, { left: 642, top: 444, width: 130, height: 92, value: "1", label: "Supervisor", accent: theme.accentSoft });
  addMetricCard(ctx, slide, { left: 790, top: 444, width: 130, height: 92, value: "1", label: "State machine", accent: theme.cyan });
  addMetricCard(ctx, slide, { left: 938, top: 444, width: 130, height: 92, value: "3+", label: "Known gaps", accent: theme.red });

  ctx.addText(slide, {
    text: "Source base: README, ARCHITECTURE.md, docs/runbook.md, Terraform modules, Lambda handlers",
    left: 642,
    top: 566,
    width: 430,
    height: 38,
    fontSize: 12,
    color: theme.muted,
  });

  addFooter(ctx, slide);
  return slide;
}
