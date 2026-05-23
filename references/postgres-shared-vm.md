# Shared Postgres VM

A single `e2-micro` Compute Engine VM in an always-free region runs Postgres in Docker for every client. This is the foundation that makes the whole architecture nearly free.

## Why this design

- `e2-micro` in `us-central1`, `us-east1`, or `us-west1` is included in the GCP Always Free tier (one instance per billing account)
- The 30 GB standard persistent disk for the boot volume is also free in this tier
- Postgres in Docker means upgrading is `docker pull postgres:17 && docker compose up -d`
- One database per client provides full isolation without paying for separate database servers
- Direct VPC Egress (GA, free) lets Cloud Run reach the VM over private IP without a Serverless VPC Connector

## What gets provisioned

This module belongs in `infra/terraform/shared/` and is applied once at the start of the project.

### `infra/terraform/shared/main.tf`

```hcl
# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID hosting all client stacks"
  type        = string
}

variable "region" {
  description = "Always-free region for the Postgres VM"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone within the always-free region"
  type        = string
  default     = "us-central1-a"
}

variable "github_repo" {
  description = "GitHub repo in 'owner/name' format for Workload Identity Federation"
  type        = string
}

# ---------------------------------------------------------------------------
# Networking — private VPC for Postgres
# ---------------------------------------------------------------------------

resource "google_compute_network" "shared_vpc" {
  name                    = "shared-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "db_subnet" {
  name          = "db-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.shared_vpc.id

  # Required for Direct VPC Egress from Cloud Run
  private_ip_google_access = true
}

# Allow Cloud Run egress (10.8.0.0/14 is the typical Cloud Run egress range
# when using Direct VPC Egress; restrict further if you allocate a static range)
resource "google_compute_firewall" "allow_postgres_from_cloudrun" {
  name      = "allow-postgres-from-cloudrun"
  network   = google_compute_network.shared_vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  # Lock down to the VPC subnet only — Cloud Run with Direct VPC Egress
  # uses IPs allocated from the connected subnet
  source_ranges = [google_compute_subnetwork.db_subnet.ip_cidr_range]
}

# SSH for emergency access only — gated by IAP, no public SSH exposed
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "allow-iap-ssh"
  network   = google_compute_network.shared_vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP TCP forwarding source range
  source_ranges = ["35.235.240.0/20"]
}

# ---------------------------------------------------------------------------
# Postgres VM
# ---------------------------------------------------------------------------

resource "google_service_account" "postgres_vm_sa" {
  account_id   = "postgres-vm"
  display_name = "Postgres VM service account"
}

# The VM only needs permission to write backups to its GCS bucket
resource "google_storage_bucket_iam_member" "postgres_vm_backup_writer" {
  bucket = google_storage_bucket.postgres_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.postgres_vm_sa.email}"
}

resource "google_compute_instance" "postgres" {
  name         = "postgres-shared"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["postgres"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"  # Container-Optimized OS — Docker built in
      size  = 30                       # GB, within free tier
      type  = "pd-standard"            # Standard persistent disk is free tier eligible
    }
  }

  # Separate persistent disk for the Postgres data directory — survives VM rebuilds
  attached_disk {
    source      = google_compute_disk.postgres_data.id
    device_name = "postgres-data"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.db_subnet.id
    # No public IP — VM is reachable only via private VPC and IAP for SSH
  }

  service_account {
    email  = google_service_account.postgres_vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Cloud-init style startup; see vm-bootstrap/startup.sh
    startup-script = file("${path.module}/../../vm-bootstrap/startup.sh")
    # Pass the backup bucket name into the VM environment
    postgres-backup-bucket = google_storage_bucket.postgres_backups.name
  }

  # Allow stopping for maintenance without losing the data disk
  allow_stopping_for_update = true
}

resource "google_compute_disk" "postgres_data" {
  name = "postgres-data"
  type = "pd-standard"
  zone = var.zone
  size = 20  # GB — generous for many clients; still cheap if it grows past free tier

  # Prevent accidental deletion; this disk holds all client data
  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Backups bucket
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "postgres_backups" {
  name          = "${var.project_id}-postgres-backups"
  location      = var.region
  force_destroy = false  # Backups are precious; don't auto-destroy on terraform destroy

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30  # Days
    }
    action {
      type = "Delete"
    }
  }

  uniform_bucket_level_access = true
}

# ---------------------------------------------------------------------------
# Artifact Registry — shared Docker image repository
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "apis" {
  location      = var.region
  repository_id = "apis"
  format        = "DOCKER"
  description   = "Docker images for client NestJS APIs"

  cleanup_policies {
    id     = "keep-last-10-per-client"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

# ---------------------------------------------------------------------------
# Workload Identity Federation for GitHub Actions
# ---------------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Restrict to the specific repo; tokens from other repos cannot impersonate
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Deploy service account — granted to GitHub via WIF
resource "google_service_account" "deploy_bot" {
  account_id   = "deploy-bot"
  display_name = "GitHub Actions deploy bot"
}

resource "google_service_account_iam_member" "github_can_impersonate_deploy_bot" {
  service_account_id = google_service_account.deploy_bot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# Permissions the deploy bot needs across all clients
locals {
  deploy_bot_roles = [
    "roles/run.admin",                 # Deploy Cloud Run services
    "roles/storage.admin",             # Upload to GCS buckets
    "roles/artifactregistry.writer",   # Push Docker images
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountUser",
  ]
}

resource "google_project_iam_member" "deploy_bot_roles" {
  for_each = toset(local.deploy_bot_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.deploy_bot.email}"
}

# ---------------------------------------------------------------------------
# Outputs — referenced by the per-client module and CI/CD secrets
# ---------------------------------------------------------------------------

output "vpc_id" {
  value = google_compute_network.shared_vpc.id
}

output "db_subnet_id" {
  value = google_compute_subnetwork.db_subnet.id
}

output "postgres_internal_ip" {
  value = google_compute_instance.postgres.network_interface[0].network_ip
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/apis"
}

output "wif_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "deploy_bot_email" {
  value = google_service_account.deploy_bot.email
}
```

## VM bootstrap script

This runs on first boot via the `startup-script` metadata. It pulls Postgres in Docker, mounts the persistent disk for the data directory, and configures the nightly backup cron.

### `infra/vm-bootstrap/startup.sh`

```bash
#!/bin/bash
# Startup script for the shared Postgres VM
# Runs once on first boot via GCE startup-script metadata

set -euo pipefail

# Read the backup bucket name from instance metadata
BACKUP_BUCKET=$(curl -sH "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postgres-backup-bucket)

# ---------------------------------------------------------------------------
# Mount the attached persistent disk at /var/lib/postgresql
# ---------------------------------------------------------------------------

DISK_DEVICE=/dev/disk/by-id/google-postgres-data
MOUNT_POINT=/mnt/postgres-data

# Format on first boot only (idempotent — skips if already a filesystem)
if ! blkid "$DISK_DEVICE"; then
  mkfs.ext4 -F "$DISK_DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mount -o discard,defaults "$DISK_DEVICE" "$MOUNT_POINT"

# Persist mount across reboots
if ! grep -q "$DISK_DEVICE" /etc/fstab; then
  echo "$DISK_DEVICE $MOUNT_POINT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
fi

# ---------------------------------------------------------------------------
# Postgres in Docker with docker-compose
# ---------------------------------------------------------------------------

mkdir -p /home/postgres
cat > /home/postgres/docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      # Superuser password is generated on first boot and stored in Secret Manager
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256"
    volumes:
      - /mnt/postgres-data:/var/lib/postgresql/data
      - /home/postgres/secrets:/run/secrets:ro
    ports:
      # Bind to private IP only — never expose externally
      - "10.10.0.2:5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF

# Generate superuser password on first boot, store in Secret Manager
if [ ! -f /home/postgres/secrets/postgres_password ]; then
  mkdir -p /home/postgres/secrets
  openssl rand -base64 32 > /home/postgres/secrets/postgres_password
  chmod 600 /home/postgres/secrets/postgres_password

  # Push to Secret Manager so the user can retrieve it
  gcloud secrets create postgres-superuser-password --replication-policy=automatic || true
  gcloud secrets versions add postgres-superuser-password \
    --data-file=/home/postgres/secrets/postgres_password
fi

cd /home/postgres
docker compose up -d

# ---------------------------------------------------------------------------
# Nightly backup to GCS — runs as cron at 03:00 UTC
# ---------------------------------------------------------------------------

cat > /usr/local/bin/postgres-backup.sh <<EOF
#!/bin/bash
# Nightly pg_dumpall to GCS
set -euo pipefail

TIMESTAMP=\$(date -u +%Y%m%d-%H%M%S)
PGPASSWORD=\$(cat /home/postgres/secrets/postgres_password) \
  docker exec -i \$(docker ps -q -f name=postgres) \
  pg_dumpall -U postgres | \
  gzip | \
  gsutil cp - gs://${BACKUP_BUCKET}/dumps/\${TIMESTAMP}.sql.gz
EOF
chmod +x /usr/local/bin/postgres-backup.sh

# Install cron entry
echo "0 3 * * * root /usr/local/bin/postgres-backup.sh" > /etc/cron.d/postgres-backup
```

## Per-client database provisioning

When Terraform's per-client module runs, it needs to create a database and role on the Postgres VM. The cleanest approach is a small Cloud Function (or local script) that connects to Postgres as superuser and runs:

```sql
-- Create role and database for a new client
CREATE ROLE client_acme_corp WITH LOGIN PASSWORD '<generated>';
CREATE DATABASE acme_corp_db OWNER client_acme_corp;
REVOKE ALL ON DATABASE acme_corp_db FROM PUBLIC;
GRANT CONNECT ON DATABASE acme_corp_db TO client_acme_corp;
```

The generated password goes into Secret Manager as `acme-corp-db-password` and is mounted into the Cloud Run service as an environment variable.

Alternatively, use Terraform's `cyrilgdn/postgresql` provider to manage this declaratively — see the per-client module reference.

## Restoring from backup

```bash
# Find the backup
gsutil ls gs://${PROJECT_ID}-postgres-backups/dumps/

# Restore (this overwrites — be careful)
gsutil cp gs://${PROJECT_ID}-postgres-backups/dumps/YYYYMMDD-HHMMSS.sql.gz - | \
  gunzip | \
  docker exec -i $(docker ps -q -f name=postgres) psql -U postgres
```

## When to graduate off this setup

The shared VM is a deliberate cost optimization, not a forever solution. Migrate a client to a dedicated Cloud SQL instance when any of these become true:

- The client has paying users whose downtime would cost more than $8/month
- Total active connections across all clients regularly exceed ~50
- Postgres memory pressure on the e2-micro becomes a recurring problem
- A client requires PITR or HA, which Cloud SQL provides out of the box

Migration path: `pg_dump` the client database, create a Cloud SQL instance, `pg_restore`, update the client's Cloud Run secret to point at the new connection string, redeploy. Roughly 30 minutes per client.
