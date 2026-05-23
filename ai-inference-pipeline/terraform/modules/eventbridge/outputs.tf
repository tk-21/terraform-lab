output "rule_name" { value = aws_cloudwatch_event_rule.s3_to_sfn.name }
output "rule_arn"  { value = aws_cloudwatch_event_rule.s3_to_sfn.arn }
