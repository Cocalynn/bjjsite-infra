variable "region" {
  type        = string
  default     = "eu-west-2"
  description = "AWS region for resources (London)."
}

variable "project" {
  type        = string
  default     = "bjj-notebook"
  description = "Project slug used in names (e.g., tfstate bucket)"
}
variable "github_owner" {
  type        = string
  default     = "Cocalynn"
  description = "GitHub org/user that owns the repo"
}
variable "github_repo" {
  type        = string
  default     = "bjjsite-infra"
  description = "Infra repo name"
}
variable "admin_user_name" {
  type        = string
  default     = "admin"
  description = "admin user name"
}
