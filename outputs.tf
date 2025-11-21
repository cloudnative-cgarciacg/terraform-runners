output "runner_internal_ip" {
  description = "Internal IP address of the GitHub Actions runner"
  value       = google_compute_instance.runner.network_interface[0].network_ip
}

output "nat_gateway_name" {
  description = "Name of the Cloud NAT gateway"
  value       = google_compute_router_nat.runner_nat.name
}