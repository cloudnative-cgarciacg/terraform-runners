variable "project_id" {
  description = "ID del proyecto de GCP"
  type        = string
}

variable "region" {
  description = "Región de GCP"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zona de GCP"
  type        = string
  default     = "europe-west1-b"
}

variable "vpc_cidr" {
  description = "CIDR de la subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "runner_machine_type" {
  description = "Tipo de máquina para el runner"
  type        = string
  default     = "e2-medium"
}

variable "proxy_machine_type" {
  description = "Tipo de máquina para el proxy"
  type        = string
  default     = "e2-small"
}

variable "github_repo_url" {
  description = "URL del repositorio u organización para el runner"
  type        = string
  # Ej: "https://github.com/cloudnative-aldotrucios"
}

variable "github_registration_token" {
  description = "Registration token del runner de GitHub"
  type        = string
  sensitive   = true
}

variable "runner_labels" {
  description = "Etiquetas del runner"
  type        = string
  default     = "gcp,self-hosted,ubuntu"
}

variable "runner_version" {
  description = "Versión del GitHub Actions runner"
  type        = string
  default     = "2.329.0"
}
