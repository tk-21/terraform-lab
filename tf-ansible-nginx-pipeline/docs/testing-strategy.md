# インフラテスト戦略

## テストピラミッド（インフラ版）

```
         /\
        /  \
       / E2E \      ← Inspec: 本番環境のポリシー準拠確認
      /--------\
     / 統合テスト \   ← Terratest: apply→assert→destroyの完全サイクル
    /------------\
   /  単体テスト   \  ← Molecule: Ansible Role単体の冪等性確認
  /--------------\
 /  静的解析      \  ← terraform validate, fmt, tflint, ansible-lint
/------------------\
```

## 各テスト層の責務

| 層 | ツール | 何を確認するか | 実行タイミング |
|----|--------|--------------|--------------|
| 静的解析 | terraform validate/fmt, ansible-lint | 構文・スタイル | PRのpush時（毎回）|
| 単体テスト | Molecule | Roleの冪等性・機能 | PRのpush時（毎回）|
| 統合テスト | Terratest | リソース作成の正確性 | PRのマージ前 |
| E2E/ポリシー | Inspec | セキュリティポリシー準拠 | apply後（毎回）|
| Drift検知 | terraform plan in CI | 手動変更の検出 | 定期実行（毎日）|

## テストの設計原則

1. **テストコードはIaCコードと同じリポジトリで管理する**
   - インフラとテストのバージョンを一致させるため

2. **テストは実際のAWSリソースを作成して確認する（Terratest）**
   - モックでは検証できない依存関係やIAMポリシーの問題を発見するため

3. **テスト後は必ずterraform destroyする**
   - コスト管理と環境のクリーン性を維持するため

4. **冪等性テストは必ず2回実行する（Molecule）**
   - 1回目: リソースの作成（changed > 0）
   - 2回目: 再実行してchanged = 0を確認する
