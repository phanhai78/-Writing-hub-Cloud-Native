# infra/terraform/envs/gcp-demo/main.tf
# Hạ tầng GCP cho demo session (~$0.50/giờ, auto-destroy sau 2h)
#
# Cấu trúc:
#   VPC private (không có node public IP)
#   GKE Autopilot (không cần manage node pool)
#   Artifact Registry (lưu Docker image)
#
# CHẠY:
#   cd infra/terraform/envs/gcp-demo
#   terraform init
#   terraform apply -var="project_id=YOUR_PROJECT_ID"
#
# DESTROY (bắt buộc sau demo để tiết kiệm credit):
#   terraform destroy -var="project_id=YOUR_PROJECT_ID"

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  # Remote state trên GCS — nhiều người có thể cộng tác.
  # Tạo bucket trước: gsutil mb gs://YOUR_PROJECT_ID-tfstate
  backend "gcs" {
    bucket = "YOUR_PROJECT_ID-tfstate"
    prefix = "taskr/gcp-demo"
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region — chọn gần Việt Nam"
  type        = string
  default     = "asia-southeast1"  # Singapore, latency ~30ms từ HN
}

variable "cluster_name" {
  description = "Tên GKE cluster"
  type        = string
  default     = "taskr-demo"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─── VPC ───
# Private VPC — node không có external IP, tăng bảo mật
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.0"

  project_id   = var.project_id
  network_name = "taskr-vpc"
  routing_mode = "REGIONAL"

  subnets = [
    {
      subnet_name           = "taskr-gke-subnet"
      subnet_ip             = "10.10.0.0/20"
      subnet_region         = var.region
      subnet_private_access = true  # Cloud NAT cho outbound internet
      subnet_flow_logs      = false # Tắt để tiết kiệm chi phí
    }
  ]

  # Secondary ranges cho GKE pods và services
  secondary_ranges = {
    taskr-gke-subnet = [
      {
        range_name    = "pods"
        ip_cidr_range = "10.20.0.0/16"
      },
      {
        range_name    = "services"
        ip_cidr_range = "10.30.0.0/20"
      }
    ]
  }
}

# Cloud NAT — cho phép node private kết nối internet (pull image, etc.)
resource "google_compute_router" "router" {
  name    = "taskr-router"
  region  = var.region
  network = module.vpc.network_name
}

resource "google_compute_router_nat" "nat" {
  name                               = "taskr-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ─── GKE Autopilot ───
# Autopilot: Google quản lý node, chỉ trả tiền cho pod (không phải node idle)
# Rẻ hơn Standard cho demo ngắn hạn.
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region  # Regional cluster (3 zone) → HA mặc định

  # Autopilot mode
  enable_autopilot = true

  network    = module.vpc.network_name
  subnetwork = module.vpc.subnets_names[0]

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster — node không có public IP
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false  # Master endpoint vẫn public (cần cho CI/CD)
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Workload Identity — pod lấy GCP credential qua service account binding
  # Không cần service account key JSON trong pod
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Release channel STABLE — ít breaking change hơn RAPID
  release_channel {
    channel = "STABLE"
  }

  # Logging/monitoring của GCP — tắt để tiết kiệm (dùng self-hosted Prometheus)
  logging_config {
    enable_components = []
  }
  monitoring_config {
    enable_components = []
  }

  deletion_protection = false  # Cho phép `terraform destroy` xóa cluster
}

# ─── Artifact Registry ───
# Nơi lưu Docker image của task-api (thay thế Docker Hub)
# Format image: asia-southeast1-docker.pkg.dev/PROJECT/taskr/task-api:TAG
resource "google_artifact_registry_repository" "taskr" {
  location      = var.region
  repository_id = "taskr"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

# ─── IAM: GitHub Actions có thể push image ───
# Dùng Workload Identity Federation (không cần service account key JSON trong CI)
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Actions Provider"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == 'YOUR_USERNAME/cloud-native-taskr'"
}

# ─── Outputs ───
output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/taskr"
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}"
}

output "estimated_cost_per_hour" {
  value = "~$0.10-0.20/giờ cho demo nhỏ (Autopilot pricing)"
}
