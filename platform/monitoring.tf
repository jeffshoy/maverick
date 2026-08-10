############################################
# CloudWatch alarms on the metrics WorkSpaces natively publishes
# per-directory (aggregated). For per-workspace alarms, add them
# in the fleet layer alongside each aws_workspaces_workspace resource.
############################################

resource "aws_sns_topic" "vdi_alerts" {
  name = "${var.project_name}-alerts"
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "${var.project_name}-in-session-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  metric_name         = "InSessionLatency"
  namespace           = "AWS/WorkSpaces"
  period              = 300
  statistic           = "Average"
  threshold           = 200 # milliseconds — tune to your baseline
  alarm_description   = "Average in-session latency exceeded threshold across the WorkSpaces fleet"
  dimensions = {
    DirectoryId = aws_workspaces_directory.vdi.id
  }
  alarm_actions = [aws_sns_topic.vdi_alerts.arn]
  ok_actions    = [aws_sns_topic.vdi_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "session_launch_time_high" {
  alarm_name          = "${var.project_name}-session-launch-time-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  metric_name         = "SessionLaunchTime"
  namespace           = "AWS/WorkSpaces"
  period              = 300
  statistic           = "Average"
  threshold           = 30 # seconds — tune to your baseline
  alarm_description   = "Average session launch time exceeded threshold"
  dimensions = {
    DirectoryId = aws_workspaces_directory.vdi.id
  }
  alarm_actions = [aws_sns_topic.vdi_alerts.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_dashboard" "vdi" {
  dashboard_name = "${var.project_name}-workspaces-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "In-Session Latency (avg)"
          region  = var.aws_region
          metrics = [["AWS/WorkSpaces", "InSessionLatency", "DirectoryId", aws_workspaces_directory.vdi.id]]
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Session Launch Time (avg)"
          region  = var.aws_region
          metrics = [["AWS/WorkSpaces", "SessionLaunchTime", "DirectoryId", aws_workspaces_directory.vdi.id]]
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "CPU Usage (avg)"
          region  = var.aws_region
          metrics = [["AWS/WorkSpaces", "CPUUsage", "DirectoryId", aws_workspaces_directory.vdi.id]]
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Root/User Volume Disk Usage (avg)"
          region  = var.aws_region
          metrics = [
            ["AWS/WorkSpaces", "RootVolumeDiskUsage", "DirectoryId", aws_workspaces_directory.vdi.id],
            ["AWS/WorkSpaces", "UserVolumeDiskUsage", "DirectoryId", aws_workspaces_directory.vdi.id]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title   = "Connected Users"
          region  = var.aws_region
          metrics = [["AWS/WorkSpaces", "UserConnected", "DirectoryId", aws_workspaces_directory.vdi.id]]
          period  = 300
          stat    = "Sum"
        }
      }
    ]
  })
}
