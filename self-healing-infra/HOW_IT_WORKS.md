# なぜ自動で直るのか（仕組みの解説）

README の手順を一通り動かした人向けの解説です。「何を実行したか」ではなく「なぜそうなるのか」を説明します。

---

## 1. ひと言でいうと

**「AWS が変更を見張っていて、違反を見つけたら AWS が合図を出し、その合図で Lambda が動く」** という、AWS サービス同士のバトンリレーです。人間もサーバーも、常時動かしているものは何もありません。

```text
SG を変更した
   │
   ▼
① AWS Config        「SG が変わったな」と記録する
   │
   ▼
② Config Rule       「SSH が 0.0.0.0/0 に開いている → 違反」と判定する
   │
   ▼
③ EventBridge       「違反が出た」という合図を受け取り、Lambda に渡す
   │
   ▼
④ Lambda            SG のルールを全部消して、正しいルールだけ入れ直す
   │
   ▼
⑤ SNS               メールで知らせる
```

それぞれの担当は次のとおりです。

| 役者 | 一言で | 誰が用意したか | 定義場所 |
|---|---|---|---|
| AWS Config Recorder | 監視カメラ。SG の変更を記録する | Terraform | `terraform/config.tf` |
| Config Rule | 審判。「これは違反」と判定する | AWS のマネージドルール | `terraform/config.tf` |
| EventBridge | 郵便配達。違反の知らせを Lambda に届ける | Terraform | `terraform/config.tf` |
| Lambda | 修理担当。SG を直す | 自作コード | `lambda/handler.py` |
| SNS | 連絡係。メールを送る | Terraform | `terraform/main.tf` |

---

## 2. 各段階で何が起きているか

### ① AWS Config: 変更を検知する

`aws_config_configuration_recorder` が、Security Group（`AWS::EC2::SecurityGroup`）の設定変更だけを記録します。全リソースではなく SG だけに絞っているのは、Config の課金を抑えるためです。

つまり、SG のルールが追加・削除された瞬間に、Config は「変更前と変更後の設定」を記録します。ポーリング（定期チェック）ではなく、変更を契機に動きます。

### ② Config Rule: 違反かどうかを判定する

`INCOMING_SSH_DISABLED` は、AWS が用意済みの判定ルールです。自分で判定ロジックを書く必要はありません。

- `0.0.0.0/0` に対して `tcp/22` が開いている → `NON_COMPLIANT`（違反）
- それ以外（`10.0.0.0/8` からの 22 番など）→ `COMPLIANT`（準拠）

判定結果が変わったとき（`COMPLIANT` → `NON_COMPLIANT` など）に、AWS が「Config Rules Compliance Change」というイベントを出します。

### ③ EventBridge: 違反の知らせだけを Lambda に渡す

EventBridge は、流れてくるイベントのうち**条件に合うものだけ**を拾います。この条件が `config.tf` の `event_pattern` です。

```text
発信元が aws.config
かつ 種類が "Config Rules Compliance Change"
かつ ルール名が no-unrestricted-ssh
かつ 新しい判定が NON_COMPLIANT
```

この条件に合うイベントが来たときだけ、ターゲットに設定した Lambda を呼び出します。

**ここが大事な点:** 条件に `NON_COMPLIANT` が入っているので、修復して `COMPLIANT` に戻ったときの通知では Lambda は起動しません。そのため「直す → 変更が入る → また検知 → また直す…」という無限ループにはなりません。

### ④ Lambda: 直す

Lambda は EventBridge から、次のような情報を受け取ります（実際のログの一部）。

```json
{
  "detail-type": "Config Rules Compliance Change",
  "detail": {
    "resourceId": "sg-064170cb79b4493bc",
    "configRuleName": "no-unrestricted-ssh",
    "newEvaluationResult": { "complianceType": "NON_COMPLIANT" }
  }
}
```

ここから `resourceId`（どの SG か）だけを取り出し、次の 3 手順で修復します（`lambda/handler.py` の `remediate_sg`）。

1. その SG の現在のインバウンドルールを全部取得する
2. 全部削除する
3. あるべきルール（`10.0.0.0/8 → tcp/22`）だけを追加する

**「違反ルールだけ消す」のではなく「全部消して正解を入れ直す」** のがポイントです。理由は次の 3 つです。

- 何が悪いルールかを判定するコードが不要になり、シンプルになる
- どんな状態から始まっても、終わりの状態が同じになる（冪等）
- 想定外の穴（0.0.0.0/0 以外の危険なルール）も一緒に消える

### ⑤ SNS: メールで知らせる

Lambda が SNS のトピックにメッセージを publish し、購読しているメールアドレスに配信されます。Lambda がメールサーバーに直接つなぐのではなく、SNS に渡すだけです。だから通知先を Slack などに変えたいときも、Lambda を直さずに SNS の購読先を足すだけで済みます。

---

## 3. Lambda はなぜ SG を書き換えられるのか（権限）

Lambda は自分の IAM ロールの権限で AWS を操作します。Terraform でこのロールに最小限の権限だけを付けています（`terraform/main.tf`）。

| 権限 | 使う場面 |
|---|---|
| `ec2:DescribeSecurityGroups` | 現在のルールを読む |
| `ec2:RevokeSecurityGroupIngress` | ルールを削除する |
| `ec2:AuthorizeSecurityGroupIngress` | 正しいルールを追加する |
| `sns:Publish`（通知トピックのみ） | メールを送る |
| ログ出力 | 実行ログを CloudWatch Logs に書く |

パスワードやアクセスキーはコードにもありません。Lambda に付いたロールから、AWS が一時的な認証情報を自動で渡します。

そして EventBridge が Lambda を呼べるのは、`aws_lambda_permission` で「EventBridge からの呼び出しを許可する」と明示しているからです。

---

## 4. Ansible はなぜ同じことができるのか

Ansible は**自動修復には関わっていません**。手元の PC から同じ修復を手動で行うための別経路です。

普通の Ansible は SSH でサーバーに入って作業しますが、この playbook は違います。

```yaml
hosts: localhost
connection: local
```

- `localhost`: 自分の PC 自身を対象にする（SSH しない）
- `connection: local`: 接続せず、自分のプロセスの中で処理する

Ansible の `amazon.aws` モジュールは、中で boto3（Python の AWS ライブラリ）を使い、**AWS の API を直接呼びます**。つまりここでの Ansible は「AWS API を呼ぶ道具」で、Lambda が boto3 で SG を直接書き換えているのと、やっていることは同じです。

```text
Lambda   ── boto3 ──▶  AWS API ──▶ SG を書き換え
Ansible  ── boto3 ──▶  AWS API ──▶ SG を書き換え（同じ結果）
```

Lambda と Ansible が同時に動いても、どちらも「全部消して正解を入れ直す」ため、最終的な状態は同じです（冪等性）。

### playbook で気をつけた点

| 点 | 理由 |
|---|---|
| `filters: group-id` で SG を取得 | `ec2_security_group_info` は `group_ids` を受け付けず、`filters` だけを受け付ける |
| `name` / `description` を既存値で渡す | `ec2_security_group` は `state: present` のとき、`group_id` だけでは動かず、この 2 つが必須 |
| 許可 CIDR をリストで 1 タスクに渡す | ループで 1 つずつ適用すると、`purge_rules: true` が前のルールを消してしまう |
| `ansible_python_interpreter` を指定 | モジュールが boto3 のある venv の Python で動くようにする |

---

## 5. 実際の動きをログで追う

README の Step 5 で実際に出たログです。時刻はすべて UTC です。

| 時刻 | 出来事 | 担当 |
|---|---|---|
| 13:57:29 | 違反ルールを追加 | 人（aws cli） |
| 13:57:38 | `NON_COMPLIANT` と判定 | Config Rule |
| 13:57:39 | 違反イベントを発行 | Config → EventBridge |
| 13:57:47 | Lambda が起動 | EventBridge → Lambda |
| 13:57:47 | `Revoked all inbound rules` | Lambda |
| 13:57:48 | `Applied compliant rules` | Lambda |
| 13:57:48 | `Email notified via SNS` | Lambda → SNS |

**約 20 秒かかる内訳:** 違反追加から判定まで約 9 秒（Config の評価待ち）、イベント配信に数秒、Lambda の実行は約 1 秒です。Lambda が遅いのではなく、Config が変更を検知して評価するまでの時間が大半です。「リアルタイム」ではなく「数十秒以内に直る」仕組みです。

---

## 6. この仕組みの限界

- **正当なルールも消える。** 「全部消して入れ直す」ため、別用途の正当なインバウンドルールがあっても消えます。本番では、対象の SG を専用にする必要があります。
- **数十秒の隙間がある。** 違反が入ってから直るまでの間、穴は開いています。予防（そもそも入れさせない）ではなく、検知と修復です。
- **通知は失敗しうる。** SG は直ったのにメールだけ届かない、という状況があり得ます。再試行の仕組みは入れていません。
- **SG の SSH（22 番）だけが対象。** 他のポートやリソースは監視していません。

---

## 7. もっと詳しく知りたいとき

- 構成図・責務分担・設計判断: [ARCHITECTURE.md](ARCHITECTURE.md)
- 手順: [README.md](README.md)
- 各コード: [config.tf](terraform/config.tf) / [main.tf](terraform/main.tf) / [handler.py](lambda/handler.py) / [fix_sg.yml](ansible/playbooks/fix_sg.yml)
