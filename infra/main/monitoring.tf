# Thresholds from AWS's recommended alarms:
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html

data "aws_sns_topic" "alarm" {
  name = "martin-project-final-s3-alarm"
}

locals {
  # The replication group's member clusters, named <group>-001, <group>-002
  valkey_clusters = toset([
    for n in range(1, aws_elasticache_replication_group.this.num_cache_clusters + 1) :
    format("%s-%03d", aws_elasticache_replication_group.this.replication_group_id, n)
  ])
}

resource "aws_cloudwatch_metric_alarm" "valkey_engine_cpu" {
  for_each = local.valkey_clusters

  alarm_name          = "martin-project-final-valkey-engine-cpu-${each.key}"
  alarm_description   = "EngineCPUUtilization of Valkey cluster ${each.key} crossed AWS's recommended threshold."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alarm.arn]
}

# 90 percent spread over the node type's 2 vCPUs (ElastiCache's rule for small nodes).
resource "aws_cloudwatch_metric_alarm" "valkey_cpu" {
  for_each = local.valkey_clusters

  alarm_name          = "martin-project-final-valkey-cpu-${each.key}"
  alarm_description   = "CPUUtilization of the Valkey node in ${each.key} crossed 90 percent of its 2 vCPUs."
  namespace           = "AWS/ElastiCache"
  metric_name         = "CPUUtilization"
  dimensions          = { CacheClusterId = each.key, CacheNodeId = "0001" }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 45
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alarm.arn]
}

resource "aws_cloudwatch_metric_alarm" "nat_port_allocation" {
  count = length(module.vpc.natgw_ids)

  alarm_name          = "martin-project-final-nat-port-allocation-${module.vpc.azs[count.index]}"
  alarm_description   = "The NAT gateway in ${module.vpc.azs[count.index]} could not allocate a source port."
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  dimensions          = { NatGatewayId = module.vpc.natgw_ids[count.index] }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alarm.arn]
}

resource "aws_cloudwatch_metric_alarm" "etcd_size" {
  alarm_name          = "martin-project-final-eks-etcd-size"
  alarm_description   = "The cluster's etcd database is above 95 percent of its 8 GiB limit."
  namespace           = "AWS/EKS"
  metric_name         = "apiserver_storage_size_bytes"
  dimensions          = { ClusterName = module.eks.cluster_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = floor(8 * 1073741824 * 0.95)
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alarm.arn]
}

# Node findings carry the cluster's tag instead of its name.
resource "aws_cloudwatch_event_rule" "guardduty" {
  name        = "martin-project-final-guardduty"
  description = "GuardDuty findings of medium, high or critical severity on cluster martin-project-final"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [for i in range(40, 101) : i / 10]
      "$or" = [
        { resource = { eksClusterDetails = { name = [module.eks.cluster_name] } } },
        { resource = { instanceDetails = { tags = { key = ["kubernetes.io/cluster/${module.eks.cluster_name}"] } } } },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty" {
  rule = aws_cloudwatch_event_rule.guardduty.name
  arn  = data.aws_sns_topic.alarm.arn

  input_transformer {
    input_paths = {
      severity            = "$.detail.severity"
      Account_ID          = "$.detail.accountId"
      Finding_ID          = "$.detail.id"
      Finding_Type        = "$.detail.type"
      region              = "$.region"
      Finding_Description = "$.detail.description"
    }
    input_template = "{\"message\":\"You have a severity <severity> GuardDuty finding type <Finding_Type> in the <region> Region.\\n\\nFinding Description:\\n<Finding_Description>\\n\\nFor more details open the GuardDuty console at https://console.aws.amazon.com/guardduty/home?region=<region>#/findings?search=id%3D<Finding_ID>\"}"
  }
}
