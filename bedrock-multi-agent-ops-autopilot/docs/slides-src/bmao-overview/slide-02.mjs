import { theme, addBackground, addHeader, addFooter, addPanel, addBullets } from "./theme.mjs";

export function slide02(presentation, ctx) {
  const slide = presentation.slides.add();
  addBackground(ctx, slide);
  addHeader(
    ctx,
    slide,
    "THESIS",
    "目的は『AIで全部置き換えること』ではなく、運用判断を安全に分業させること。",
    "README と ADR から読み取れる設計思想を、採用理由とトレードオフに分けて整理した。"
  );

  addPanel(ctx, slide, {
    left: 64,
    top: 176,
    width: 538,
    height: 424,
    title: "なぜ単一エージェントではないのか",
    subtitle: "AWS運用は調査・分析・修復・通知で要求能力が異なる。",
  });
  addBullets(ctx, slide, {
    left: 88,
    top: 240,
    width: 478,
    items: [
      "障害調査は CloudWatch / X-Ray / Config の横断読解が必要",
      "コスト最適化は Cost Explorer と EC2 の読み取り中心",
      "修復は危険度が高く、承認と権限制御が最優先",
      "レポートは人に伝わる形へ再構成する別能力が必要",
      "全部を 1 つの prompt に詰めると責務が膨らみ、改善単位も粗くなる",
    ],
  });

  addPanel(ctx, slide, {
    left: 632,
    top: 176,
    width: 584,
    height: 194,
    title: "採用した答え",
    subtitle: "Supervisor + Sub-agent パターン",
  });
  addBullets(ctx, slide, {
    left: 656,
    top: 242,
    width: 536,
    lineHeight: 30,
    items: [
      "Supervisor は Sonnet で状況判断と委譲だけを担当",
      "専門作業は Haiku Sub-agent に逃がしてコストを抑制",
      "Bedrock Multi-Agent Collaboration のネイティブ委譲をそのまま活用",
    ],
  });

  addPanel(ctx, slide, {
    left: 632,
    top: 392,
    width: 584,
    height: 208,
    title: "この設計で得るもの / 支払うもの",
    subtitle: "ADR-001 の内容を理解用に要約",
  });

  ctx.addText(slide, {
    text: "得るもの",
    left: 656,
    top: 446,
    width: 180,
    height: 22,
    fontSize: 16,
    color: theme.green,
    bold: true,
  });
  addBullets(ctx, slide, {
    left: 656,
    top: 476,
    width: 230,
    lineHeight: 24,
    fontSize: 14,
    items: ["責務分離", "モデルコスト最適化", "個別改善しやすい構造"],
  });

  ctx.addText(slide, {
    text: "支払うもの",
    left: 934,
    top: 446,
    width: 180,
    height: 22,
    fontSize: 16,
    color: theme.red,
    bold: true,
  });
  addBullets(ctx, slide, {
    left: 934,
    top: 476,
    width: 236,
    lineHeight: 24,
    fontSize: 14,
    items: ["IAM と agent 間配線が複雑", "呼び出し回数増による遅延", "委譲設計ミス時の不整合リスク"],
  });

  addFooter(ctx, slide);
  return slide;
}
