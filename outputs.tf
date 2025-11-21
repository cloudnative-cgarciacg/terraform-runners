output "runner_internal_ip" {
  value       = google_compute_instance.runner.network_interface[0].network_ip
  description = "IP interna del runner"
}

output "proxy_internal_ip" {
  value       = google_compute_instance.proxy.network_interface[0].network_ip
  description = "IP interna del proxy"
}

output "proxy_external_ip" {
  value       = google_compute_instance.proxy.network_interface[0].access_config[0].nat_ip
  description = "IP pública del proxy"
}
