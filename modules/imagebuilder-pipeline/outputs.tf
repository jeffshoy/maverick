output "component_arns" {
  description = "ARNs of the custom CIS-hardening components created for this pipeline"
  value       = { for k, v in aws_imagebuilder_component.cis : k => v.arn }
}

output "recipe_arn" {
  description = "ARN of the image recipe"
  value       = aws_imagebuilder_image_recipe.this.arn
}

output "infrastructure_configuration_arn" {
  description = "ARN of the infrastructure configuration"
  value       = aws_imagebuilder_infrastructure_configuration.this.arn
}

output "distribution_configuration_arn" {
  description = "ARN of the distribution configuration"
  value       = aws_imagebuilder_distribution_configuration.this.arn
}

output "pipeline_arn" {
  description = "ARN of the image pipeline"
  value       = aws_imagebuilder_image_pipeline.this.arn
}
