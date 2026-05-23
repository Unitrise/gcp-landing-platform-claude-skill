# Per-client Terraform module

A single reusable module that provisions everything one customer needs: a GCS bucket for the landing page, another for the dashboard, a Cloud Run service for the API, a Postgres database and role, Secret Manager entries, and DNS records.

Adding a customer is then one block in `infra/terraform/clients.tf` plus `terraform apply`.

## Module structure

### `infra/terraform/modules/client-stack/variables.tf`

```hcl
variable "client_id" {
  description = "Lowercase identifier used in resource names (e.g. 'acme-corp')"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.client_id))
    error_message = "client_id must be lowercase letters, digits, and dashes only."
  }
}

variable "domain" {
  description = "Apex domain for the landing page (e.g. 'acme.com')"
  type        = string
}

variable "dashboard_subdomain" {
  description = "Subdomain hosting the admin dashboard"
  type        = string
  default     = "admin"
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Run and storage"
  type        = string
  default     = "us-central1"
}

variable "vpc_id" {
  description = "Shared VPC self-link from the shared infra module"
  type        = string
}

variable "db_subnet_id" {
  description = "Subnet self-link the Cloud Run service egresses through"
  type        = string
}

variable "postgres_host" {
  description = "Private IP of the shared Postgres VM"
  type        = string
}

variable "artifact_registry" {
  description = "Artifact Registry path for Docker images"
  type        = string
}

variable "firebase_project_id" {
  description = "Firebase project ID used for dashboard auth"
  type        = string
}
```

### `infra/terraform/modules/client-stack/main.tf`

```hcl
# ---------------------------------------------------------------------------
# Local naming conventions — every resource is namespaced by client_id
# ---------------------------------------------------------------------------

locals {
  landing_bucket   = "${var.project_id}-${var.client_id}-landing"
  dashboard_bucket = "${var.project_id}-${var.client_id}-dashboard"
  cloud_run_name   = "${var.client_id}-api"
  db_name          = "${replace(var.client_id, "-", "_")}_db"
  db_role          = "client_${replace(var.client_id, "-", "_")}"
}

# ---------------------------------------------------------------------------
# Database password — randomly generated, stored in Secret Manager
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  length  = 32
  special = true
  # Avoid characters that complicate connection strings
  override_special = "!#$%&*+-_="
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.client_id}-db-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# ---------------------------------------------------------------------------
# Postgres database and role
#
# Uses the cyrilgdn/postgresql provider — the parent terraform must configure
# this provider pointing at the shared Postgres VM (see providers.tf in shared/)
# ---------------------------------------------------------------------------

resource "postgresql_role" "client" {
  name     = local.db_role
  login    = true
  password = random_password.db.result
}

resource "postgresql_database" "client" {
  name              = local.db_name
  owner             = postgresql_role.client.name
  encoding          = "UTF8"
  lc_collate        = "en_US.utf8"
  lc_ctype          = "en_US.utf8"
  connection_limit  = 50
}

# ---------------------------------------------------------------------------
# GCS buckets — landing page and dashboard static files
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "landing" {
  name          = local.landing_bucket
  location      = var.region
  force_destroy = false

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  # Public read so Cloudflare can serve the files
  uniform_bucket_level_access = true

  cors {
    origin          = ["https://${var.domain}"]
    method          = ["GET", "HEAD"]
    response_header = ["*"]
    max_age_seconds = 3600
  }
}

resource "google_storage_bucket_iam_member" "landing_public" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket" "dashboard" {
  name          = local.dashboard_bucket
  location      = var.region
  force_destroy = false

  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"  # SPA fallback
  }

  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "dashboard_public" {
  bucket = google_storage_bucket.dashboard.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ---------------------------------------------------------------------------
# Cloud Run service — the client's NestJS API
# ---------------------------------------------------------------------------

resource "google_service_account" "api_sa" {
  account_id   = "${var.client_id}-api"
  display_name = "${var.client_id} API service account"
}

# Allow the API to read its own database password
resource "google_secret_manager_secret_iam_member" "api_can_read_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_sa.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name     = local.cloud_run_name
  location = var.region

  # Direct VPC Egress — free, replaces Serverless VPC Connector
  template {
    service_account = google_service_account.api_sa.email

    scaling {
      min_instance_count = 0  # Scale to zero when idle
      max_instance_count = 10
    }

    vpc_access {
      network_interfaces {
        network    = var.vpc_id
        subnetwork = var.db_subnet_id
      }
      egress = "ALL_TRAFFIC"  # All egress through VPC; required to reach Postgres
    }

    containers {
      # CI/CD updates the image tag; Terraform sets the initial placeholder
      image = "${var.artifact_registry}/${var.client_id}-api:bootstrap"

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
        # CPU is only allocated during request processing — cheapest mode
        cpu_idle = true
      }

      env {
        name  = "DATABASE_URL"
        value = "postgresql://${local.db_role}:${random_password.db.result}@${var.postgres_host}:5432/${local.db_name}?sslmode=require"
      }

      env {
        name  = "FIREBASE_PROJECT_ID"
        value = var.firebase_project_id
      }

      env {
        name  = "ALLOWED_ORIGINS"
        value = "https://${var.domain},https://${var.dashboard_subdomain}.${var.domain}"
      }

      env {
        name  = "CLIENT_ID"
        value = var.client_id
      }
    }
  }

  # Allow Terraform to ignore image changes since CI/CD manages them
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

# Allow public invocations — auth is enforced inside the NestJS app
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------------------------------------------------------------------------
# DNS records (managed in Cloudflare via the cloudflare provider)
# ---------------------------------------------------------------------------

resource "cloudflare_record" "landing" {
  zone_id = data.cloudflare_zone.client.id
  name    = "@"
  type    = "CNAME"
  content = "c.storage.googleapis.com"
  proxied = true  # Cloudflare proxy handles SSL + CDN
}

resource "cloudflare_record" "dashboard" {
  zone_id = data.cloudflare_zone.client.id
  name    = var.dashboard_subdomain
  type    = "CNAME"
  content = "c.storage.googleapis.com"
  proxied = true
}

resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.client.id
  name    = "api"
  type    = "CNAME"
  # Cloud Run gives each service a *.run.app hostname; map it through Cloudflare
  content = trimprefix(google_cloud_run_v2_service.api.uri, "https://")
  proxied = true
}

data "cloudflare_zone" "client" {
  name = var.domain
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "landing_bucket" {
  value = google_storage_bucket.landing.name
}

output "dashboard_bucket" {
  value = google_storage_bucket.dashboard.name
}

output "cloud_run_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "db_password_secret" {
  value = google_secret_manager_secret.db_password.secret_id
}
```

## Adding a new client

In `infra/terraform/clients.tf`:

```hcl
module "acme_corp" {
  source = "./modules/client-stack"

  client_id           = "acme-corp"
  domain              = "acme.com"
  project_id          = var.project_id
  region              = var.region
  vpc_id              = module.shared.vpc_id
  db_subnet_id        = module.shared.db_subnet_id
  postgres_host       = module.shared.postgres_internal_ip
  artifact_registry   = module.shared.artifact_registry
  firebase_project_id = "acme-corp-landing"
}

module "client_two" {
  source = "./modules/client-stack"

  client_id           = "client-two"
  domain              = "clienttwo.io"
  # ... rest of inputs
}
```

Then `terraform apply`. The module is idempotent — re-running it is safe and only changes resources whose configuration has drifted.

## Why Cloudflare instead of Cloud DNS + Load Balancer

The Cloud DNS + HTTPS Load Balancer + managed SSL combination on GCP costs about $18/month minimum (mostly the load balancer's forwarding rule base fee). Cloudflare gives the same outcome — SSL on a custom domain, CDN caching, DDoS protection — for free, including unlimited bandwidth on the static file paths.

The trade-off: requests go through Cloudflare's network rather than Google's premium tier. For a marketing landing page this is invisible to users. If a client later needs guaranteed GCP-only routing, swap to a Load Balancer for just that one client.

## State management

Terraform state lives in a GCS bucket with versioning enabled. Configure once in `infra/terraform/backend.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "<project-id>-terraform-state"
    prefix = "platform"
  }
}
```

Create the state bucket manually before the first `terraform init`:

```bash
gsutil mb -p $PROJECT_ID -l us-central1 gs://$PROJECT_ID-terraform-state
gsutil versioning set on gs://$PROJECT_ID-terraform-state
```

## Provider configuration

In `infra/terraform/providers.tf`:

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.23"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Postgres provider connects to the shared VM via the bastion or directly
# (depends on the runner location; CI runners need a tunnel or IAP)
provider "postgresql" {
  host      = module.shared.postgres_internal_ip
  port      = 5432
  username  = "postgres"
  password  = data.google_secret_manager_secret_version.pg_superuser.secret_data
  sslmode   = "require"
  superuser = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```
