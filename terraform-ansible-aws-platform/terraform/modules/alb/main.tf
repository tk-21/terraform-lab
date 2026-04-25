# =============================================================================
# ALBモジュール
# インターネット向けALBを2AZに配置し、AppサーバーEC2へトラフィックを振り分ける。
# HTTPリスナーのみ実装（HTTPS化はACM証明書取得後にlistener追加で拡張可能）。
# =============================================================================

# -----------------------------------------------------------------------------
# ALB本体
# public_subnet_idsに2AZ分のサブネットを渡すことで、
# AZ障害時も片方のAZで継続してリクエストを受け付けられる構成にする。
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false           # インターネット向けALB（外部公開用）
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids  # 2AZに配置してAZ冗長性を確保

  # アクセスログ・削除保護は本番環境での拡張を想定し今回は省略
  tags = {
    Name = "${var.project}-${var.environment}-alb"
    Role = "alb"
  }
}

# -----------------------------------------------------------------------------
# Target Group
# ALBからAppサーバーへの振り分け先グループ。
# ヘルスチェックパスは /api/health を使用し、
# Flaskアプリが正常に起動しているかを確認する（Nginxの静的応答では不十分なため）。
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-${var.environment}-app-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/api/health"     # Flaskアプリのヘルスチェックエンドポイント
    healthy_threshold   = 2                 # 2回連続成功で正常判定（素早く復旧を検知）
    unhealthy_threshold = 3                 # 3回連続失敗で異常判定（一時的なスパイクを除外）
    interval            = 30               # 30秒ごとにヘルスチェック実施
    timeout             = 10               # 10秒以内に応答がなければタイムアウト
    matcher             = "200"            # 200 OKのみ正常とみなす
  }

  tags = {
    Name = "${var.project}-${var.environment}-app-tg"
    Role = "app"
  }
}

# -----------------------------------------------------------------------------
# HTTP:80 Listener
# ALBへのHTTP:80リクエストをTarget Groupへ転送する。
# 将来的にACM証明書を取得した際は、HTTPSリスナーを追加してHTTPリダイレクトに変更する。
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# -----------------------------------------------------------------------------
# Target Group Attachment
# app_instance_idsリストに含まれる全EC2インスタンスをTarget Groupに登録する。
# for_eachを使用することで、インスタンス数が変わっても宣言的に管理できる。
# -----------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "app" {
  for_each = toset(var.app_instance_ids)

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = each.value
  port             = 80
}
