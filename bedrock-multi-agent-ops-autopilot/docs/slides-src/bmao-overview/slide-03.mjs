import { theme, addBackground, addHeader, addFooter, addPanel, addConnector } from "./theme.mjs";

function node(ctx, slide, left, top, width, height, title, subtitle, fill) {
  ctx.addShape(slide, {
    left,
    top,
    width,
    height,
    geometry: "roundRect",
    fill,
    line: ctx.line(theme.line, 1),
  });
  ctx.addText(slide, {
    text: title,
    left: left + 14,
    top: top + 14,
    width: width - 28,
    height: 22,
    fontSize: 16,
    color: theme.text,
    bold: true,
    align: "center",
  });
  ctx.addText(slide, {
    text: subtitle,
    left: left + 14,
    top: top + 40,
    width: width - 28,
    height: height - 52,
    fontSize: 11,
    color: theme.muted,
    align: "center",
  });
}

export function slide03(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "SYSTEM MAP",
    "判断は Bedrock、実作業は Lambda へ落とす。",
    "Step Functions は長い業務ロジックではなく、Supervisor 呼び出しのラッパーとして使われている。"
  );

  addPanel(ctx, slide, {
    left: 54,
    top: 176,
    width: 1170,
    height: 452,
    title: "End-to-end architecture",
    subtitle: "構想図と実装コードの共通部分だけに絞って再描画",
  });

  node(ctx, slide, 86, 272, 172, 80, "Trigger", "EventBridge\nCost anomaly / Alarm", "#152742");
  node(ctx, slide, 296, 272, 180, 80, "Orchestrator", "Step Functions\nrecords start / end", "#173055");
  node(ctx, slide, 514, 258, 208, 108, "Supervisor Agent", "Claude 3.7 Sonnet\nBedrock native collaboration", "#21436d");

  node(ctx, slide, 780, 188, 184, 70, "Incident Investigator", "CloudWatch / X-Ray / Config", "#1d2d4e");
  node(ctx, slide, 986, 188, 184, 70, "Cost Optimizer", "Cost Explorer / EC2 read-only", "#1d2d4e");
  node(ctx, slide, 780, 286, 184, 70, "Remediation", "Approval request / SSM command", "#39233b");
  node(ctx, slide, 986, 286, 184, 70, "Reporter", "HTML report / Chatwork", "#193544");

  node(ctx, slide, 780, 404, 184, 76, "Approval Table", "DynamoDB\nhuman-in-the-loop state", "#112033");
  node(ctx, slide, 986, 404, 184, 76, "Execution History", "DynamoDB\nrun audit trail", "#112033");
  node(ctx, slide, 882, 516, 184, 76, "Reports & Notify", "S3 HTML + Chatwork", "#143225");

  addConnector(ctx, slide, { left: 258, top: 310, width: 38 });
  addConnector(ctx, slide, { left: 476, top: 310, width: 38 });
  addConnector(ctx, slide, { left: 722, top: 220, width: 58 });
  addConnector(ctx, slide, { left: 722, top: 318, width: 58 });
  addConnector(ctx, slide, { left: 964, top: 223, width: 22, fill: theme.accent });
  addConnector(ctx, slide, { left: 964, top: 321, width: 22, fill: theme.accent });
  addConnector(ctx, slide, { left: 872, top: 356, width: 4, height: 48, fill: theme.red });
  addConnector(ctx, slide, { left: 1080, top: 356, width: 4, height: 48, fill: theme.cyan });
  addConnector(ctx, slide, { left: 960, top: 480, width: 20, height: 36, fill: theme.green });

  ctx.addText(slide, {
    text: "Sub-agent layer",
    left: 778,
    top: 152,
    width: 180,
    height: 18,
    fontSize: 11,
    color: theme.accent,
    face: ctx.fonts.mono,
  });
  ctx.addText(slide, {
    text: "Human approval is isolated here",
    left: 774,
    top: 368,
    width: 190,
    height: 18,
    fontSize: 10,
    color: theme.red,
    face: ctx.fonts.mono,
  });
  ctx.addText(slide, {
    text: "Current Step Functions logic stops at invoke + status update",
    left: 292,
    top: 366,
    width: 250,
    height: 28,
    fontSize: 11,
    color: theme.muted,
  });

  addFooter(ctx, slide);
  return slide;
}
