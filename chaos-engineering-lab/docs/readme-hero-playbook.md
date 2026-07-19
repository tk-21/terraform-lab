# README Hero Playbook

他のプロジェクトでも同じ流れで README 用画像を作るための最小運用ガイド。

## すすめ方
1. 対象リポジトリに `docs/readme-hero-spec.md` を置く
2. 必要なら `AGENTS.md` に README 画像ポリシーを追加する
3. Codex に「README 用画像を作って README に入れて」と依頼する
4. 差し替え後に README の見え方だけ確認する

## まずコピーするファイル
- `docs/templates/AGENTS.readme-hero.template.md`
- `docs/templates/readme-hero-spec.template.md`
- `.codex/skills/readme-hero-generator/SKILL.md`

## おすすめ運用
- 全プロジェクト共通の方針は共通 `AGENTS.md` か共通スキルに寄せる
- 各プロジェクト固有の訴求点は `docs/readme-hero-spec.md` に寄せる
- 出力先はできるだけ `docs/readme-hero.png` に統一する

## Codex への依頼例
```text
README 用の画像を作成して、README に埋め込んでください。
docs/readme-hero-spec.md を優先して、横長で見やすい構成にしてください。
```

## 補足
- README 冒頭では、縦長ポスターより横長ヒーロー画像のほうが視認性が高い
- 画像だけで詳細を説明しきろうとせず、全体像の理解に役割を絞ると安定しやすい
