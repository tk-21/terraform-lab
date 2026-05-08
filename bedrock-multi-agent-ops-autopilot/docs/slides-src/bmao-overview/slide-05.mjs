import { theme, addBackground, addHeader, addFooter, addPanel, addConnector } from "./theme.mjs";

function flowRow(ctx, slide, top, label, steps, accent) {
  ctx.addText(slide, {
    text: label,
    left: 84,
    top: top + 28,
    width: 150,
    height: 24,
    fontSize: 18,
    color: accent,
    bold: true,
  });
  let left = 228;
  steps.forEach((step, index) => {
    const width = step.width || 170;
    ctx.addShape(slide, {
      left,
      top: top,
      width,
      height: 86,
      geometry: "roundRect",
      fill: index === steps.length - 1 ? "#143225" : theme.panelAlt,
      line: ctx.line(theme.line, 1),
    });
    ctx.addText(slide, {
      text: step.title,
      left: left + 14,
      top: top + 14,
      width: width - 28,
      height: 20,
      fontSize: 14,
      color: theme.text,
      bold: true,
      align: "center",
    });
    ctx.addText(slide, {
      text: step.body,
      left: left + 12,
      top: top + 38,
      width: width - 24,
      height: 34,
      fontSize: 11,
      color: theme.muted,
      align: "center",
    });
    if (index < steps.length - 1) {
      addConnector(ctx, slide, { left: left + width, top: top + 40, width: 24, fill: accent });
    }
    left += width + 24;
  });
}

export function slide05(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "EXECUTION FLOW",
    "入口は違っても、最終的には同じ Supervisor ループに収束する。",
    "実装上は Step Functions が短く、判断ロジックの重心は Bedrock Supervisor 側にある。"
  );

  addPanel(ctx, slide, { left: 64, top: 182, width: 1152, height: 440, title: "Two entry flows, one orchestration core", subtitle: "README / runbook / ASL / Lambda 実装を突き合わせた結果" });

  flowRow(ctx, slide, 246, "Cost anomaly", [
    { title: "Cost Anomaly Detection", body: "サービス単位の異常を検知" },
    { title: "EventBridge", body: "detail を anomaly_id / total_impact に整形" },
    { title: "Step Functions", body: "RUNNING を記録して Supervisor invoke" },
    { title: "Supervisor", body: "Cost Optimizer / Reporter / 必要なら Remediation へ委譲", width: 220 },
    { title: "Outcome", body: "SUCCEEDED or FAILED only", width: 170 },
  ], theme.accent);

  flowRow(ctx, slide, 386, "Incident alarm", [
    { title: "CloudWatch Alarm", body: "ALARM 遷移を発火" },
    { title: "EventBridge", body: "alarm_name / state / reason を抽出" },
    { title: "Step Functions", body: "同じ state machine で処理" },
    { title: "Supervisor", body: "Investigator 中心で調査し、必要に応じて報告や修復へ分岐", width: 220 },
    { title: "Outcome", body: "状態更新は同一", width: 170 },
  ], theme.cyan);

  ctx.addText(slide, {
    text: "重要: Step Functions には承認待ちループ、Wait、再開制御はまだない。承認の中心は Remediation Lambda 側に寄っている。",
    left: 84,
    top: 560,
    width: 1092,
    height: 28,
    fontSize: 14,
    color: theme.red,
    bold: true,
  });

  addFooter(ctx, slide);
  return slide;
}
