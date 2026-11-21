output "node_instance_id" {
  value = aws_instance.node.id
}

output "node_public_ip" {
  value = aws_eip.node.public_ip
}

output "dashboard_urls" {
  description = "nip.io turns <name>.<ip>.nip.io into <ip>, so each env gets its own hostname with no DNS setup"
  value       = { for env in var.environments : env => "http://${env}.${aws_eip.node.public_ip}.nip.io" }
}

output "ecr_image_repo" {
  value = aws_ecr_repository.this["app"].repository_url
}

output "ecr_chart_repo" {
  value = aws_ecr_repository.this["chart"].repository_url
}

output "dynamodb_tables" {
  value = { for env, t in aws_dynamodb_table.app : env => t.name }
}

output "azure_devops_iam_user" {
  description = "Create an access key for this user and put it in the 'aws-cloudpulse' ADO service connection"
  value       = aws_iam_user.azure_devops.name
}

output "ssm_shell" {
  description = "Open a shell on the node without SSH"
  value       = "aws ssm start-session --target ${aws_instance.node.id} --region ${var.region}"
}
