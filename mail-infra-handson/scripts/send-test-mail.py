#!/usr/bin/env python3
"""
SES APIでテストメールを送信するスクリプト

boto3のSESv2 APIを直接使用（Postfix SMTPを経由しない方法）
SES APIが正しく設定されているか、DKIM/SPFが付与されているかを確認できる

使用方法:
  python3 scripts/send-test-mail.py \\
    --from sender@your-domain.com \\
    --to recipient@example.com \\
    --region ap-northeast-1

サンドボックスモードの注意:
  送信先は SES で検証済みのメールアドレスのみ受け付ける
  AWSコンソール > SES > Verified identities で宛先アドレスを事前に検証すること
"""

import argparse
import sys

import boto3
from botocore.exceptions import ClientError


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="SES APIでテストメールを送信する",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
バウンスシミュレーターアドレス（本番アカウント停止リスクなし）:
  bounce@simulator.amazonses.com      -- ハードバウンスをシミュレート
  ooto@simulator.amazonses.com        -- 不在通知（ソフトバウンス）
  complaint@simulator.amazonses.com   -- 苦情をシミュレート
  suppressionlist@simulator.amazonses.com -- サプレッションリスト登録済み
        """,
    )
    parser.add_argument("--from", dest="sender", required=True, help="送信元アドレス（SES検証済みドメイン）")
    parser.add_argument("--to", dest="recipient", required=True, help="宛先アドレス（サンドボックスでは検証済みのみ）")
    parser.add_argument("--region", default="ap-northeast-1", help="AWSリージョン（デフォルト: ap-northeast-1）")
    parser.add_argument(
        "--config-set",
        default="mail-handson-config-set",
        help="SES Configuration Set名（デフォルト: mail-handson-config-set）",
    )
    parser.add_argument("--subject", default="【SESハンズオン】Phase 3 テストメール", help="メール件名")
    return parser.parse_args()


def build_html_body(sender: str, recipient: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="ja">
<body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
  <h2 style="color: #232f3e;">SES Phase 3 テスト送信</h2>
  <p>このメールは <strong>AWS SES API (SESv2)</strong> から送信されました。</p>
  <table style="border-collapse: collapse; width: 100%; margin: 20px 0;">
    <tr style="background: #f5f5f5;">
      <td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">送信元</td>
      <td style="padding: 8px; border: 1px solid #ddd;">{sender}</td>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">宛先</td>
      <td style="padding: 8px; border: 1px solid #ddd;">{recipient}</td>
    </tr>
  </table>
  <hr style="border: none; border-top: 1px solid #eee;">
  <h3>確認ポイント</h3>
  <ul>
    <li>受信トレイに届いているか（スパムフォルダも確認）</li>
    <li>メールヘッダーに <code>X-SES-Message-ID</code> が含まれているか</li>
    <li><code>Received</code> ヘッダーに <code>amazonses.com</code> が含まれているか</li>
    <li><code>DKIM-Signature</code> ヘッダーが付与されているか（Phase 4で詳しく学ぶ）</li>
    <li><code>Authentication-Results</code> で spf=pass / dkim=pass を確認</li>
  </ul>
  <p style="color: #666; font-size: 0.9em;">
    ヘッダーの確認方法（Gmail）: メール右上「⋮」→「メールのソースを表示」
  </p>
</body>
</html>"""


def send_email(sender: str, recipient: str, region: str, config_set: str, subject: str) -> str:
    """SESv2 APIでHTMLメールを送信しMessageIdを返す"""

    client = boto3.client("sesv2", region_name=region)

    response = client.send_email(
        FromEmailAddress=sender,
        Destination={"ToAddresses": [recipient]},
        Content={
            "Simple": {
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {
                    "Html": {"Data": build_html_body(sender, recipient), "Charset": "UTF-8"},
                    "Text": {
                        "Data": (
                            f"SES Phase 3 テスト送信\n\n"
                            f"送信元: {sender}\n宛先: {recipient}\n\n"
                            "このメールはAWS SES APIから送信されました。"
                        ),
                        "Charset": "UTF-8",
                    },
                },
            }
        },
        # Configuration Setを指定することでバウンス・苦情・配信イベントが記録される
        ConfigurationSetName=config_set,
    )

    return response["MessageId"]


def main() -> None:
    args = parse_args()

    print(f"送信元:          {args.sender}")
    print(f"宛先:            {args.recipient}")
    print(f"リージョン:      {args.region}")
    print(f"ConfigurationSet: {args.config_set}")
    print()

    try:
        message_id = send_email(
            sender=args.sender,
            recipient=args.recipient,
            region=args.region,
            config_set=args.config_set,
            subject=args.subject,
        )

        print("送信成功")
        print(f"  MessageId: {message_id}")
        print()
        print("【次の確認ポイント】")
        print("1. 受信メールのヘッダーを確認する")
        print("   Gmail: メール右上「⋮」→「メールのソースを表示」")
        print(f"   X-SES-Message-ID: {message_id} と一致しているか確認")
        print()
        print("2. Authentication-Results ヘッダーで SPF/DKIM を確認")
        print("   spf=pass   → SPFレコードが正しく設定されている")
        print("   dkim=pass  → SES Easy DKIMが機能している（Phase 4で詳細解説）")
        print()
        print("3. CloudWatchでSESメトリクスを確認")
        print("   aws cloudwatch list-metrics --namespace AWS/SES --region " + args.region)
        print()
        print("4. バウンスをテストするには SESシミュレーターアドレスへ送信:")
        print("   --to bounce@simulator.amazonses.com      # ハードバウンス")
        print("   --to complaint@simulator.amazonses.com   # 苦情")
        print()
        print("5. DynamoDBでサプレッションリストを確認:")
        print(f"   aws dynamodb scan --table-name mail-handson-suppression-list --region {args.region}")

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        error_msg = e.response["Error"]["Message"]
        print(f"送信失敗: {error_code}", file=sys.stderr)
        print(f"  {error_msg}", file=sys.stderr)

        if error_code == "MessageRejected":
            print()
            print("【サンドボックスモードの制限】", file=sys.stderr)
            print("宛先アドレスがSESで検証済みでない可能性があります。", file=sys.stderr)
            print("AWSコンソール > SES > Verified identities でアドレスを検証してください。", file=sys.stderr)
        elif error_code == "MailFromDomainNotVerifiedException":
            print()
            print("【ドメイン未検証】", file=sys.stderr)
            print("送信元ドメインがSESで検証されていません。", file=sys.stderr)
            print("terraform apply 後にドメイン検証が完了するまで数分待ってください。", file=sys.stderr)
            print(f"確認: aws sesv2 get-email-identity --email-identity {args.sender.split('@')[1]} --region {args.region}", file=sys.stderr)

        sys.exit(1)


if __name__ == "__main__":
    main()
