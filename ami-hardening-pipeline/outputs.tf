output "logs_bucket_name" {
  description = "S3 bucket storing CIS compliance evidence for all pipelines"
  value       = module.imagebuilder_core.logs_bucket_name
}

output "windows2019_pipeline_arn" {
  value = module.windows2019_pipeline.pipeline_arn
}

output "windows2022_pipeline_arn" {
  value = module.windows2022_pipeline.pipeline_arn
}

output "rhel9_pipeline_arn" {
  value = module.rhel9_pipeline.pipeline_arn
}

output "ubuntu2204_pipeline_arn" {
  value = module.ubuntu2204_pipeline.pipeline_arn
}

output "rhel9_resolved_ami_id" {
  description = "RHEL 9 parent AMI ID used by the recipe (explicit override or auto-resolved from Marketplace)"
  value       = local.resolved_rhel9_ami_id
}

output "ubuntu2204_resolved_ami_id" {
  description = "Ubuntu 22.04 Pro parent AMI ID used by the recipe (explicit override or auto-resolved from Canonical)"
  value       = local.resolved_ubuntu2204_ami_id
}
