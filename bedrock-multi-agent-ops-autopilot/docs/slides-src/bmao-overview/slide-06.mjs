import { theme, addBackground, addHeader, addFooter, addPanel } from "./theme.mjs";

const rows = [
  ["Supervisor", "Sonnet", "状況判断 / 委譲", "なし", "Sub-agent へ collaborator 委譲"],
  ["Incident Investigator", "Haiku", "障害調査", "CloudWatch / X-Ray / Config", "読み取り専用"],
  ["Cost Optimizer", "Haiku", "コスト分析", "CE / EC2 describe", "提案のみで変更しない"],
  ["Remediation", "Haiku", "承認付き修復", "DynamoDB / SSM / Chatwork", "approved のみ実行"],
  ["Reporter", "Haiku", "レポート通知", "S3 / presigned URL / Chatwork", "人間に返す最終成果物"],
];

export function slide06(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "AGENT MATRIX",
    "『調査』『提案』『修復』『報告』の線引きが、このプロジェクトの分かりやすさを作っている。",
    "Terraform agents module と各 Lambda handler の対応関係を一覧化した。"
  );

  addPanel(ctx, slide, { left: 64, top: 182, width: 1152, height: 438, title: "Role-to-implementation matrix", subtitle: "Action Group と IAM の責務境界も同時に把握する" });

  const cols = [86, 290, 448, 646, 904];
  ["Agent", "Model", "Primary role", "Action surface", "Safety stance"].forEach((label, index) => {
    ctx.addText(slide, {
      text: label,
      left: cols[index],
      top: 232,
      width: [180, 120, 180, 230, 250][index],
      height: 20,
      fontSize: 13,
      color: theme.accent,
      bold: true,
      face: ctx.fonts.mono,
    });
  });

  rows.forEach((row, rIndex) => {
    const top = 268 + rIndex * 64;
    ctx.addShape(slide, {
      left: 84,
      top,
      width: 1098,
      height: 48,
      geometry: "roundRect",
      fill: rIndex % 2 === 0 ? theme.panelAlt : theme.panelSoft,
      line: ctx.line(theme.line, 1),
    });
    row.forEach((value, cIndex) => {
      ctx.addText(slide, {
        text: value,
        left: cols[cIndex],
        top: top + 12,
        width: [180, 120, 180, 230, 250][cIndex],
        height: 24,
        fontSize: cIndex === 0 ? 14 : 12,
        color: cIndex === 1 ? theme.cyan : theme.text,
        bold: cIndex === 0,
      });
    });
  });

  ctx.addText(slide, {
    text: "Guardrail は Supervisor と全 Sub-agent に共通適用される。『危険な指示をしない』だけでなく、Remediation の IAM から危険権限を外す二重防御になっている。",
    left: 84,
    top: 596,
    width: 1098,
    height: 26,
    fontSize: 13,
    color: theme.muted,
  });

  addFooter(ctx, slide);
  return slide;
}
