# ✅Phase 2: GCP 構築

## 目標

AWSで構築した同一ワークロードをGCPに展開する。
「AWSとの概念差異を身体で感じる」ことが主目的。
コードを書きながら「なぜGCPはこう設計したのか」を考える。

---

## 事前準備

```bash
# GCPプロジェクトIDを環境変数に設定（自分のプロジェクトIDに変更）
export TF_VAR_project_id="your-gcp-project-id"

# Application Default Credentials の設定
gcloud auth application-default login

# 必要なAPIの有効化
gcloud services enable compute.googleapis.com
```

---

## 作成するファイル

### `gcp/main.tf`

```hcl
# cloud-agnostic-infra-lab / GCP
# AWSベースラインとの差異を日本語コメントで明示しながら実装する

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# VPC Network
# AWSと最大の違い: GCPのVPCはグローバルリソース（リージョンを跨ぐ）
# AWSは「リージョンごとにVPCを作る」設計だがGCPは1つのVPCが全リージョンをカバー
# ---------------------------------------------------------------------------
resource "google_compute_network" "main" {
  name                    = "${var.project}-vpc"
  auto_create_subnetworks = false # サブネットを手動管理するため無効化
}

# ---------------------------------------------------------------------------
# Subnetwork
# GCPのサブネットはリージョン単位（AWSはAZ単位 — ここが大きな差異）
# AWSで「AZごとにサブネットを分ける」感覚でやると設計が冗長になる
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "public" {
  name          = "${var.project}-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.main.id
}

# ---------------------------------------------------------------------------
# Firewall Rules
# AWSのセキュリティグループとの根本的な違い:
#   AWS SG = ステートフル（戻りのトラフィックは自動許可）
#   GCP Firewall = ステートフル（実はGCPも5.0以降はステートフル対応）
# しかしリソースへのアタッチ方法が違う:
#   AWS = ENIにSGをアタッチ
#   GCP = ネットワークタグ or サービスアカウントで対象を指定
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_http_lb" {
  name    = "${var.project}-allow-http-lb"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  # ヘルスチェックのIPレンジ（GCP固有の概念 — AWSにはない）
  source_ranges = ["0.0.0.0/0", "35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["nginx-server"]
}

# SSHアクセス（IAP経由 — AWSのSession Managerに相当するGCPの仕組み）
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.project}-allow-iap-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAPのIPレンジのみ許可（直接SSH禁止）
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["nginx-server"]
}

# ---------------------------------------------------------------------------
# Instance Template
# AWSのLaunch Templateに相当するが設計思想が異なる
# GCPはテンプレートに直接ネットワーク設定を書く（AWSはLT + SG分離）
# ---------------------------------------------------------------------------
resource "google_compute_instance_template" "nginx" {
  name_prefix  = "${var.project}-"
  machine_type = "e2-micro" # 無料枠対象（vCPU 0.25相当、月720時間まで無料）

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.public.id

    # 外部IPを付与（NAT不使用のため）
    access_config {}
  }

  # ネットワークタグでFirewallルールを適用（AWSのSGとは概念が異なる）
  tags = ["nginx-server"]

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    cat > /var/www/html/index.html << 'HTML'
    <h1>cloud-agnostic-infra-lab: GCP</h1>
    <p>Region: asia-northeast1 | IaC: Terraform | Compute: e2-micro (Free Tier)</p>
    HTML
    systemctl enable --now nginx
  EOF

  # Spotインスタンス相当（GCPではPreemptible VM）
  scheduling {
    preemptible        = true
    automatic_restart  = false
    on_host_maintenance = "TERMINATE"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Health Check
# AWSのTarget Group Health CheckはTGに内包されているが
# GCPはHealth Checkが独立したリソースとして存在する（再利用可能）
# ---------------------------------------------------------------------------
resource "google_compute_health_check" "nginx" {
  name               = "${var.project}-hc"
  check_interval_sec = 15
  timeout_sec        = 5

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

# ---------------------------------------------------------------------------
# Managed Instance Group (MIG)
# AWSのAuto Scaling Groupに相当
# 大きな違い: GCPのMIGはリージョンMIGでマルチゾーン自動分散できる
# AWSはAZを明示的に指定する必要がある
# ---------------------------------------------------------------------------
resource "google_compute_region_instance_group_manager" "nginx" {
  name   = "${var.project}-mig"
  region = var.region

  base_instance_name = "${var.project}-vm"

  version {
    instance_template = google_compute_instance_template.nginx.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.nginx.id
    initial_delay_sec = 60
  }

  target_size = 1
}

# ---------------------------------------------------------------------------
# Load Balancer
# GCPのLBはAWSより「部品の組み合わせ」感が強い
# Backend Service → URL Map → Target HTTP Proxy → Forwarding Rule の連鎖
# AWSはALB単体でこれをカバーしている（シンプルだが柔軟性は低い）
# ---------------------------------------------------------------------------
resource "google_compute_backend_service" "nginx" {
  name                  = "${var.project}-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_health_check.nginx.id]

  backend {
    group           = google_compute_region_instance_group_manager.nginx.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "nginx" {
  name            = "${var.project}-url-map"
  default_service = google_compute_backend_service.nginx.id
}

resource "google_compute_target_http_proxy" "nginx" {
  name    = "${var.project}-http-proxy"
  url_map = google_compute_url_map.nginx.id
}

resource "google_compute_global_forwarding_rule" "nginx" {
  name                  = "${var.project}-forwarding-rule"
  target                = google_compute_target_http_proxy.nginx.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL"
}

locals {
  common_labels = {
    project     = var.project
    environment = var.env
    managed_by  = "terraform"
    cloud       = "gcp"
  }
}
```

### `gcp/variables.tf`

```hcl
variable "project_id" {
  description = "GCPプロジェクトID（AWSのアカウントIDに相当）"
  type        = string
}

variable "region" {
  description = "GCPリージョン"
  type        = string
  default     = "asia-northeast1" # 東京
}

variable "project" {
  description = "プロジェクト識別子（ラベル・リソース名に使用）"
  type        = string
  default     = "cail"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}
```

### `gcp/outputs.tf`

```hcl
output "lb_ip_address" {
  description = "LBのグローバルIPアドレス（疎通確認に使用）"
  value       = google_compute_global_forwarding_rule.nginx.ip_address
}

output "network_name" {
  description = "VPCネットワーク名（AWSのVPC IDに相当するが概念が異なる）"
  value       = google_compute_network.main.name
}
```

---

## 実行手順

```bash
cd gcp
terraform init
terraform plan
terraform apply -auto-approve

# LBのIPが払い出されるまで2〜3分かかる（AWSのALBより遅い場合がある）
LB_IP=$(terraform output -raw lb_ip_address)
echo "LB IP: $LB_IP"

# ヘルスチェック通過まで待機してから確認
sleep 120
curl http://$LB_IP
# → <h1>cloud-agnostic-infra-lab: GCP</h1> が返ればOK
```

---

## 完了チェックリスト

- [ ] `terraform apply` が0 errorsで完了
- [ ] `curl http://<LB_IP>` でnginxレスポンス確認
- [ ] VMがPreemptible（Spot相当）として起動していることをコンソールで確認
- [ ] NAT Gatewayに相当するCloud NATが作成されていないことを確認

---

## 口頭説明チェックポイント（phase2完了後に必ず実施）

1. GCPのVPCがグローバルリソースであることの実務上のメリット・デメリットは何か
2. ネットワークタグによるFirewall適用とAWSのSGの違いをセキュリティ観点で説明せよ
3. MIGのリージョン分散とAWSのAZ指定、どちらが運用しやすいか・その理由は
4. GCPのLBがAWSのALBより部品数が多い理由は何か（設計思想の違い）

---

## 後片付け

```bash
cd gcp
terraform destroy -auto-approve
```