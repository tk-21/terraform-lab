import { theme, addBackground, addHeader, addFooter, addPanel, addMetricCard, addBullets } from "./theme.mjs";

export function slide07(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "SAFETY + COST",
    "このプロジェクトの価値は自動化そのものより、『危険な自動化をどう抑えるか』まで設計している点にある。",
    "セキュリティ設計・承認設計・モデルコスト設計を一枚に統合した。"
  );

  addMetricCard(ctx, slide, { left: 64, top: 188, width: 168, height: 92, value: "$20", label: "monthly cost target", accent: theme.accent });
  addMetricCard(ctx, slide, { left: 250, top: 188, width: 168, height: 92, value: "30d", label: "Supervisor session memory", accent: theme.cyan });
  addMetricCard(ctx, slide, { left: 436, top: 188, width: 168, height: 92, value: "24h", label: "approval TTL", accent: theme.green });
  addMetricCard(ctx, slide, { left: 622, top: 188, width: 168, height: 92, value: "90d", label: "S3 report archive", accent: theme.accentSoft });
  addMetricCard(ctx, slide, { left: 808, top: 188, width: 168, height: 92, value: "365d", label: "S3 report deletion", accent: theme.red });

  addPanel(ctx, slide, { left: 64, top: 314, width: 360, height: 296, title: "Safety controls", subtitle: "コードから確認できた安全装置" });
  addBullets(ctx, slide, {
    left: 88,
    top: 380,
    width: 312,
    lineHeight: 28,
    fontSize: 14,
    items: [
      "Guardrail で destructive operations を DENY",
      "Remediation IAM から terminate / delete / iam:* を除外",
      "承認テーブルの status を確認しないと SSM 実行不可",
      "Step Functions / Lambda とも X-Ray, logs を有効化",
    ],
  });

  addPanel(ctx, slide, { left: 448, top: 314, width: 360, height: 296, title: "Cost controls", subtitle: "ADR と Terraform から読み取れる意図" });
  addBullets(ctx, slide, {
    left: 472,
    top: 380,
    width: 312,
    lineHeight: 28,
    fontSize: 14,
    items: [
      "判断だけ Sonnet、専門処理は Haiku",
      "Step Functions 側で invoke timeout / retry を制御",
      "Cost anomaly threshold は 50 USD 固定値で作成",
      "必要以上の自動修復より『提案で止める』寄りの思想",
    ],
  });

  addPanel(ctx, slide, { left: 832, top: 314, width: 384, height: 296, title: "Operational nuance", subtitle: "運用時に誤解しやすいポイント" });
  addBullets(ctx, slide, {
    left: 856,
    top: 380,
    width: 336,
    lineHeight: 28,
    fontSize: 14,
    items: [
      "runbook の承認値は APPROVED / REJECTED",
      "Lambda 実装は approved / pending_approval",
      "Reporter は /bmao/s3/reports_bucket を追加前提で参照",
      "安全思想は強いが、運用導線はまだ補強途中",
    ],
  });

  addFooter(ctx, slide);
  return slide;
}
