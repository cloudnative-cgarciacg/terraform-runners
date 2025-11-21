# Replace the values below with your own configuration.  Do not commit
# sensitive values (such as github_token) to source control.

project_id  = "hale-monument-477117-k8"
region      = "us-central1"
zone        = "us-central1-a"

# The GitHub organisation or repository URL where the self‑hosted runner will
# register.  For example: "https://github.com/my-org" or
# "https://github.com/my-org/my-repo".
github_repo_url = "https://github.com/cloudnative-aldotrucios"

# Registration token for the self‑hosted runner.  Generate this token from
# GitHub (Settings → Actions → Runners → New runner) immediately before
# running `terraform apply`.
github_token    = "AFA3YWFVAVLROLGK4XY4LR3JEDOCE"

# Optional: customise labels and machine type if required.
runner_labels   = "self‑hosted,gcp"
machine_type    = "e2-medium"