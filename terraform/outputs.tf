# These outputs are the contract between Terraform and the CD workflow.
# .github/workflows/cd.yml reads them (or the equivalent GitHub variables) to
# know which cluster to talk to and where to push images.

output "aws_region" {
  description = "Region everything was created in."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name. Feed to: aws eks update-kubeconfig --name <this>"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "ecr_repository_url" {
  description = "Image repository. Push tags here."
  value       = aws_ecr_repository.app.repository_url
}

output "app_irsa_role_arn" {
  description = "IAM role the application's ServiceAccount assumes. Goes in the eks.amazonaws.com/role-arn annotation in k8s/serviceaccount.yaml."
  value       = aws_iam_role.app.arn
}

output "k8s_namespace" {
  description = "Namespace the application is deployed into."
  value       = local.k8s_namespace
}

output "k8s_service_account" {
  description = "ServiceAccount name the IRSA trust policy is scoped to."
  value       = local.k8s_service_account
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding DATABASE_URL."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Secrets Manager secret name, for: aws secretsmanager get-secret-value --secret-id <this>"
  value       = aws_secretsmanager_secret.db.name
}

output "db_endpoint" {
  description = "RDS hostname. Private -- resolvable only inside the VPC."
  value       = aws_db_instance.main.address
}

output "cloudwatch_log_group" {
  description = "Application log group. See cloudwatch.md for how to read it."
  value       = aws_cloudwatch_log_group.app.name
}

output "read_db_secret_policy_arn" {
  description = "Attach to the CI IAM user so GitHub Actions can read the database secret."
  value       = aws_iam_policy.read_db_secret.arn
}

# Not marked sensitive on purpose -- it is only a hostname and a username.
output "kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

# Marked sensitive so it is redacted from CLI output and CI logs. Read it
# deliberately with: terraform output -raw database_url
output "database_url" {
  description = "Full PostgreSQL connection string, including the password."
  value       = "postgresql://${var.db_username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}"
  sensitive   = true
}
