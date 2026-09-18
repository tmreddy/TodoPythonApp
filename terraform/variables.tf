variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for every resource. Change it to run a second, isolated stack in the same account."
  type        = string
  default     = "todo"

  validation {
    # Used in EKS, RDS and ECR names, which reject uppercase and underscores.
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase letters, digits and hyphens, starting with a letter (max 21 chars)."
  }
}

variable "environment" {
  description = "Environment name, used in tags."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------- networking --

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many availability zones to spread across. EKS and RDS both require at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2: EKS requires subnets in two AZs, and so does an RDS subnet group."
  }
}

# ---------------------------------------------------------------------- EKS --

variable "kubernetes_version" {
  description = "EKS control plane version. AWS supports each version for a limited window, so this needs bumping periodically."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = <<-EOT
    EC2 instance type for worker nodes. t3.small (2 GB) fits the system pods
    plus a few replicas of this app. Move to t3.medium if pods sit Pending with
    "Insufficient memory", or if you hit the per-instance pod limit -- on AWS the
    pod ceiling is set by how many ENIs and IPs the instance type allows, not by
    CPU.
  EOT
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = "Number of worker nodes to run."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum worker nodes."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum worker nodes the group may scale to."
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "EBS volume size per node, in GB."
  type        = number
  default     = 20
}

variable "cluster_admin_role_arns" {
  description = <<-EOT
    Extra IAM principal ARNs to grant cluster-admin, beyond whoever runs apply.
    The identity that creates an EKS cluster gets admin implicitly; every other
    identity -- including GitHub Actions, if it uses a different user -- must be
    granted access explicitly or kubectl returns "error: You must be logged in
    to the server (Unauthorized)".
  EOT
  type        = list(string)
  default     = []
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint. Defaults to anywhere so GitHub Actions runners can deploy; narrow it if you self-host runners."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------- RDS --

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = <<-EOT
    PostgreSQL major.minor version. Must be a version RDS currently offers for
    this instance class in this region -- verified orderable for db.t3.micro in
    us-east-1. Check before changing:
      aws rds describe-orderable-db-instance-options --engine postgres \
        --db-instance-class db.t3.micro --query 'OrderableDBInstanceOptions[].EngineVersion'
  EOT
  type        = string
  default     = "18.6"
}

variable "db_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name created inside the instance."
  type        = string
  default     = "todo_db"
}

variable "db_username" {
  description = "RDS master username. 'admin', 'root' and 'postgres' are reserved by RDS."
  type        = string
  default     = "todouser"
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ. Roughly doubles database cost; off for learning."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Block accidental deletion. Leave false while learning so terraform destroy actually works."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------- app --

variable "app_port" {
  description = "Port the container listens on. Must match EXPOSE in the Dockerfile."
  type        = number
  default     = 8000
}

variable "cloudwatch_log_group" {
  description = "Log group the application ships request logs to (see cloudwatch.md)."
  type        = string
  default     = "todo-api-logs"
}

variable "log_retention_days" {
  description = "Retention for application and EKS control plane logs. Never leave this unset in a real account -- the default is 'forever'."
  type        = number
  default     = 7
}
