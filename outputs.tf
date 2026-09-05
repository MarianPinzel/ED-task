output "db_password_secret_arn" {
  description = "ARN of the DB password secret (safe to print, not the value)"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "api_key_secret_arn" {
  description = "ARN of the API key secret (safe to print, not the value)"
  value       = aws_secretsmanager_secret.api_key.arn
}

output "ssh_key_secret_arn" {
  description = "ARN of the SSH deploy key secret (safe to print, not the value)"
  value       = aws_secretsmanager_secret.ssh_key.arn
}

output "db_password_value" {
  description = "The actual DB password - marked sensitive, hidden by default in CLI output/logs"
  value       = random_password.db_password.result
  sensitive   = true
}

output "instance_public_ip" {
  description = "Public IP of the test EC2 instance"
  value       = aws_instance.app.public_ip
}

output "instance_role_arn" {
  description = "IAM role attached to the instance (least-privilege secrets reader)"
  value       = aws_iam_role.app_role.arn
}