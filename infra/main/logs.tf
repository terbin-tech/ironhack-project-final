# Created before the add-on, which would otherwise create them with no retention.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = toset(["application", "dataplane", "host", "performance"])

  name              = "/aws/containerinsights/${module.eks.cluster_name}/${each.key}"
  retention_in_days = 7
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = "v7.0.1-eksbuild.1"

  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch.arn
    service_account = "cloudwatch-agent"
  }

  configuration_values = jsonencode({
    manager = { applicationSignals = { autoMonitor = { monitorAllServices = false } } }
  })

  depends_on = [aws_cloudwatch_log_group.container_insights]
}
