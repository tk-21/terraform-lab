import { theme, addBackground, addHeader, addFooter, addPanel, addBullets } from "./theme.mjs";

export function slide04(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "CODEBASE MAP",
    "理解の近道は『Terraform が骨格、agents と lambda が中身、stepfunctions が境界』と分けて読むこと。",
    "ファイル構成をそのまま責務マップに変換した。"
  );

  addPanel(ctx, slide, { left: 64, top: 182, width: 272, height: 396, title: "terraform/", subtitle: "AWS リソースの定義本体" });
  addBullets(ctx, slide, {
    left: 88,
    top: 246,
    width: 224,
    lineHeight: 26,
    fontSize: 14,
    items: [
      "root main.tf で 4 modules を束ねる",
      "foundation: S3 / DDB / SSM / roles",
      "lambda: 4 Action Group Lambdas",
      "agents: Guardrail + agents + collaborators",
      "stepfunctions: state machine + EventBridge",
    ],
  });

  addPanel(ctx, slide, { left: 356, top: 182, width: 272, height: 396, title: "agents/", subtitle: "Bedrock Agent の振る舞い定義" });
  addBullets(ctx, slide, {
    left: 380,
    top: 246,
    width: 224,
    lineHeight: 26,
    fontSize: 14,
    items: [
      "supervisor/instruction.txt",
      "incident_investigator/*",
      "cost_optimizer/*",
      "remediation/*",
      "reporter/*",
    ],
  });

  addPanel(ctx, slide, { left: 648, top: 182, width: 272, height: 396, title: "lambda/", subtitle: "Action Group の実処理" });
  addBullets(ctx, slide, {
    left: 672,
    top: 246,
    width: 224,
    lineHeight: 26,
    fontSize: 14,
    items: [
      "investigator: 調査 API を束ねる",
      "cost: anomaly / rightsizing / unused",
      "remediation: approval + SSM",
      "reporter: HTML + presigned URL + Chatwork",
      "全関数で Powertools と X-Ray を使用",
    ],
  });

  addPanel(ctx, slide, { left: 940, top: 182, width: 272, height: 396, title: "stepfunctions/ + docs/", subtitle: "実行境界と説明資料" });
  addBullets(ctx, slide, {
    left: 964,
    top: 246,
    width: 224,
    lineHeight: 26,
    fontSize: 14,
    items: [
      "ops_orchestrator.asl.json が本体",
      "README は導入手順と期待像",
      "ARCHITECTURE.md は現実とのギャップ整理",
      "runbook は運用手順のつもり",
      "ADR は設計意図の根拠",
    ],
  });

  ctx.addText(slide, {
    text: "読む順番の推奨: README → terraform/main.tf → modules/stepfunctions → ASL → modules/agents → agents/* → lambda/* → runbook",
    left: 64,
    top: 614,
    width: 1148,
    height: 28,
    fontSize: 14,
    color: theme.accentSoft,
    bold: true,
  });

  addFooter(ctx, slide);
  return slide;
}
