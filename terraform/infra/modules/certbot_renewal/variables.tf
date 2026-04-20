variable "control_domain" {
  type        = string
  description = "Root domain for infrastructure."
}

variable "zone_id" {
  type        = string
  description = "Route 53 Zone ID for the control domain."
}

variable "email" {
  type        = string
  description = "Contact email for Let's Encrypt certificate registration."
}

variable "image_tag" {
  type        = string
  description = "Docker image tag for the certbot Lambda. Rotating this on each deploy is what actually updates the Lambda's container — a bare ':latest' reference looks unchanged to Terraform and leaves the Lambda running the previously-pushed image."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "ecs_cluster_name" {
  type        = string
  description = "Name of the ECS cluster running mail services."
}

variable "ecs_service_names" {
  type        = list(string)
  description = "Names of ECS services to restart after certificate renewal."
}
