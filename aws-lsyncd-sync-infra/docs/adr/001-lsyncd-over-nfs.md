# ADR-001: ファイル同期に NFS ではなく lsyncd を採用

## ステータス: 採用済み

## コンテキスト

master EC2 の `/var/www/html` を slave EC2 × 2 にリアルタイム同期する方式を選定。
NFS マウントと lsyncd + rsync over SSH の 2 案を検討した。

## 決定

lsyncd + rsync over SSH を採用する。

## 理由

| 観点 | NFS | lsyncd + rsync |
|---|---|---|
| 単一障害点 | NFS サーバが SPOF | slave は直前の同期内容を保持 |
| セキュリティ | NFS ポート開放が必要 | SSH のみ（ポート 22）で完結 |
| 帯域効率 | 全 I/O がネットワーク経由 | 差分のみ転送 |
| 実装複雑さ | NFS サーバ設定・マウント管理が必要 | lsyncd 1 つで完結 |
| ポートフォリオ観点 | 一般的すぎる | inotify + rsync の仕組みを示せる |

## トレードオフ

- lsyncd は非同期（デフォルト 5 秒遅延）。NFS は即時反映。
- ネットワーク分断時、slave が古い状態になる可能性がある。
- ハンズオン用途ではこの遅延は許容範囲と判断した。
