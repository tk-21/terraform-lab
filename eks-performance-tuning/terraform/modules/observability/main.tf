resource "random_password" "grafana" {
  length  = 16
  special = true
}

resource "aws_ssm_parameter" "grafana_password" {
  name  = "/ept/${var.environment}/grafana/admin-password"
  type  = "SecureString"
  value = random_password.grafana.result

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_ssm_parameter" "grafana_password" {
  name       = aws_ssm_parameter.grafana_password.name
  depends_on = [aws_ssm_parameter.grafana_password]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "observability"
  create_namespace = true
  version          = "61.3.2"

  values = [file("${path.module}/values/prometheus-stack.yaml")]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = data.aws_ssm_parameter.grafana_password.value
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = var.prometheus_retention
  }

  set {
    name  = "grafana.service.type"
    value = var.grafana_service_type
  }
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.14.3"
}
