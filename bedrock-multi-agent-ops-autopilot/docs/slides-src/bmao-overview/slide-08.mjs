import { theme, addBackground, addHeader, addFooter, addPanel, addBullets } from "./theme.mjs";

export function slide08(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "CURRENT STATE",
    "完成形の構想と、今のコードが担う範囲は分けて見る。",
    "ARCHITECTURE.md で明示されているギャップを、オンボーディング向けに整理した。"
  );

  addPanel(ctx, slide, { left: 64, top: 186, width: 348, height: 382, title: "すでにできていること", subtitle: "PoC として価値が出ている部分" });
  addBullets(ctx, slide, {
    left: 88,
    top: 248,
    width: 300,
    lineHeight: 28,
    fontSize: 14,
    items: [
      "Terraform で基盤と agents を一通り作れる",
      "Supervisor から 4 Sub-agent へネイティブ委譲できる",
      "Action Group Lambda が具体的な AWS API を叩ける",
      "EventBridge から Step Functions 起動まで通る",
      "実行履歴と承認の受け皿がある",
    ],
  });

  addPanel(ctx, slide, { left: 438, top: 186, width: 348, height: 382, title: "次に直すと理解が締まる点", subtitle: "実装ギャップの中心" });
  addBullets(ctx, slide, {
    left: 462,
    top: 248,
    width: 300,
    lineHeight: 28,
    fontSize: 14,
    items: [
      "承認待ちループを Step Functions 側に持たせる",
      "Reporter 用 SSM パラメータを Terraform 管理に寄せる",
      "execution-history のキー整合を remediation と合わせる",
      "runbook と実装で status 値を統一する",
      "alert threshold の変数と実リソースを一致させる",
    ],
  });

  addPanel(ctx, slide, { left: 812, top: 186, width: 404, height: 382, title: "このプロジェクトを完全理解する読み順", subtitle: "最短で迷わないルート" });
  addBullets(ctx, slide, {
    left: 836,
    top: 248,
    width: 356,
    lineHeight: 26,
    fontSize: 14,
    items: [
      "1. README で目指す体験を掴む",
      "2. terraform/main.tf でモジュール境界を見る",
      "3. modules/stepfunctions と ASL で実行範囲を把握する",
      "4. modules/agents と supervisor.tf で委譲配線を見る",
      "5. lambda/*/handler.py で『実際に何をするか』を読む",
      "6. ARCHITECTURE.md で構想との差分を確認する",
    ],
  });

  ctx.addText(slide, {
    text: "結論: このリポジトリは『AI 運用自動化の最終形』ではなく、『安全な multi-agent 運用自動化をどう組み上げるか』を具体コードで見せる教材として非常に強い。",
    left: 64,
    top: 606,
    width: 1148,
    height: 28,
    fontSize: 15,
    color: theme.accentSoft,
    bold: true,
  });

  addFooter(ctx, slide);
  return slide;
}
