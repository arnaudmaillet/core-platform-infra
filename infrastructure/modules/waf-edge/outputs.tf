# infrastructure/modules/waf-edge/outputs.tf

output "web_acl_arn" {
  description = "ARN of the client-edge Web ACL. Fed to the envsubst CMP as WAF_EDGE_ACL_ARN and set on the client-edge Ingress (alb.ingress.kubernetes.io/wafv2-acl-arn)."
  value       = aws_wafv2_web_acl.client_edge.arn
}

output "web_acl_name" {
  description = "Name of the client-edge Web ACL (the WebACL dimension of its CloudWatch metrics)."
  value       = aws_wafv2_web_acl.client_edge.name
}

output "log_group_name" {
  description = "CloudWatch log group receiving the Web ACL's logs."
  value       = aws_cloudwatch_log_group.waf.name
}
