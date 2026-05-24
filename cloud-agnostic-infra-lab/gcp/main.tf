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
#   AWS SG = ENIにアタッチ（リソース単位）
#   GCP Firewall = ネットワークタグ or サービスアカウントで対象を指定（タグ単位）
# どちらもステートフルだが、適用方式が根本的に異なる
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_http_lb" {
  name    = "${var.project}-allow-http-lb"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  # GCPのグローバルLBがヘルスチェックに使うIPレンジ（AWSにはない概念）
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
# AWSのLaunch Templateに相当するが、ネットワーク設定をテンプレート内に書く点が異なる
# AWSはLT + SGを分離してアタッチするが、GCPはテンプレートに直接埋め込む
# ---------------------------------------------------------------------------
resource "google_compute_instance_template" "nginx" {
  name_prefix  = "${var.project}-"
  machine_type = "e2-micro" # 無料枠対象（月720時間まで無料）

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.public.id

    # NAT不使用のため外部IPを直接付与（Cloud NATを建てないコスト最適化）
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

  # Preemptible VM = AWSのSpotインスタンス相当（最大80%削減）
  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  labels = local.common_labels

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Health Check
# AWSのTarget Group Health CheckはTGに内包されているが
# GCPはHealth Checkが独立したリソースとして存在する（複数MIGで再利用可能）
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
# リージョンMIGはマルチゾーンに自動分散（AWSはAZを明示指定する必要がある）
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
# GCPのLBはAWSより「部品の組み合わせ」設計
# Backend Service → URL Map → Target HTTP Proxy → Forwarding Rule の連鎖
# AWSはALB単体でこれをカバー（シンプルだが柔軟性は低い）
# GCPはグローバルLBがデフォルト — AWSはRegional/Globalを選択する
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
