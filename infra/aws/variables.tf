variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "cloudpulse"
}

variable "region" {
  description = "AWS region (eu-west-1 = Ireland)"
  type        = string
  default     = "eu-west-1"
}

variable "environments" {
  description = "App environments. Each one gets a k8s namespace and its own DynamoDB table."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "instance_type" {
  description = "EC2 size for the k3s node. t3.small (2 GiB) is comfortable; t3.micro (free tier) works but is tight."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "allowed_http_cidrs" {
  description = "Who can reach the dashboards on port 80. Lock this to your own IP (x.x.x.x/32) if you like."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alert_email" {
  description = "Optional email for CloudWatch alarms (you must confirm the SNS subscription email)."
  type        = string
  default     = ""
}

variable "k3s_channel" {
  description = "k3s release channel"
  type        = string
  default     = "stable"
}

variable "helm_version" {
  type    = string
  default = "v3.17.0"
}
