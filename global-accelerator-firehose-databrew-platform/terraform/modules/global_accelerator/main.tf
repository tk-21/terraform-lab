resource "aws_globalaccelerator_accelerator" "this" {
  name            = "${var.name_prefix}-accelerator"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = var.raw_bucket_name
    flow_logs_s3_prefix = "global-accelerator-flow-logs/"
  }
}

resource "aws_globalaccelerator_listener" "this" {
  accelerator_arn = aws_globalaccelerator_accelerator.this.id
  client_affinity = "NONE"
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "this" {
  listener_arn                  = aws_globalaccelerator_listener.this.id
  endpoint_group_region         = "ap-northeast-1"
  traffic_dial_percentage       = 100
  health_check_path             = "/health"
  health_check_protocol         = "HTTP"
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = var.alb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}
