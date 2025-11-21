variable "project_id" {
  description = "The GCP project id in which resources will be created"
  type        = string
}

variable "region" {
  description = "The region in which to create networking resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The zone for the runner VM"
  type        = string
  default     = "us-central1-a"
}

variable "network_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "machine_type" {
  description = "Machine type for the runner VM"
  type        = string
  default     = "e2-medium"
}

variable "github_repo_url" {
  description = "URL of the GitHub organisation or repository where the runner will register"
  type        = string
}

variable "github_token" {
  description = "GitHub registration token used to register the self‑hosted runner"
  type        = string
  sensitive   = true
}

variable "runner_labels" {
  description = "Comma‑separated labels to assign to the GitHub runner"
  type        = string
  default     = "self‑hosted,gcp"
}

variable "runner_version" {
  description = "Version of the GitHub Actions runner to install"
  type        = string
  default     = "2.329.0"
}