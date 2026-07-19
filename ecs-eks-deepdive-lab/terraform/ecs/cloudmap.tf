resource "aws_service_discovery_http_namespace" "main" {
  name = "deepdive.local"
  # Service Connect は Cloud Map の HTTP namespace を使用する
  # DNS namespace（aws_service_discovery_private_dns_namespace）とは異なり
  # Envoy サイドカーがプロキシするため DNS ではなく HTTP で解決する
}
