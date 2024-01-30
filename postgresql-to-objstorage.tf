# Infrastructure for Yandex Cloud Managed Service for PostgreSQL, Yandex Object Storage, and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/mpg-to-objstorage
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/mpg-to-objstorage

# Specify the following settings
locals {
  pg_password = "" # Set a password for the PostgreSQL admin user
  folder_id   = "" # Set your cloud folder ID, same as for provider
  bucket      = "" # Set a unique bucket name

  # Specify these settings ONLY AFTER the clusters are created. Then run "terraform apply" command again
  # You should set up the target endpoint using the GUI to obtain its ID
  objstorage_endpoint_id = "" # Set the target endpoint ID
  transfer_enabled       = 0  # Value '0' disables creating of transfer before the target endpoint is created manually. After that, set to '1' to enable transfer
}

# Resources for the Managed Service for PostgreSQL

resource "yandex_vpc_network" "mpg_network" {
  description = "Network for Managed Service for PostgreSQL"
  name        = "mpg_network"
}

resource "yandex_vpc_subnet" "mpg_subnet-a" {
  description    = "Subnet ru-central1-a availability zone for PostgreSQL"
  name           = "mpg_subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mpg_network.id
  v4_cidr_blocks = ["10.129.0.0/24"]
}

resource "yandex_vpc_security_group" "mpg_security_group" {
  network_id  = yandex_vpc_network.mpg_network.id
  name        = "Managed PostgreSQL security group"
  description = "Security group for Managed Service for PostgreSQL"

  ingress {
    description    = "Allow incoming traffic from the port 6432"
    protocol       = "TCP"
    port           = 6432
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow outgoing traffic to members of the same security group"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_mdb_postgresql_user" "pg-user" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = "pg-user"
  password   = local.pg_password
}

resource "yandex_mdb_postgresql_database" "mpg-db" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = "db1"
  owner      = yandex_mdb_postgresql_user.pg-user.name
  depends_on = [
    yandex_mdb_postgresql_user.pg-user
  ]
}

resource "yandex_mdb_postgresql_cluster" "mpg-cluster" {
  description        = "Managed PostgreSQL cluster"
  name               = "mpg-cluster"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.mpg_network.id
  security_group_ids = [yandex_vpc_security_group.mpg_security_group.id]

  config {
    version = 14
    resources {
      resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-ssd"
      disk_size          = "20" # GB
    }
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.mpg_subnet-a.id
    assign_public_ip = true
  }
}

# Resources for Yandex Object Storage bucket

resource "yandex_iam_service_account" "storage-sa" {
  description = "A service account to manage buckets"
  folder_id   = local.folder_id
  name        = "storage-sa"
}

# Grant permissions to the service account
resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = local.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.storage-sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  description        = "Static access key for Object Storage"
  service_account_id = yandex_iam_service_account.storage-sa.id
}

# Use keys to create a bucket
resource "yandex_storage_bucket" "obj-storage-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = local.bucket
}

# Endpoint and transfer configurations

resource "yandex_datatransfer_endpoint" "mpg-source" {
  description = "Source endpoint for PostgreSQL cluster"
  name        = "mpg-source"
  settings {
    postgres_source {
      connection {
        mdb_cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
      }
      database = "db1"
      user     = "pg-user"
      password {
        raw = local.pg_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "mpg-to-objstorage-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Managed Service for PostgreSQL to the Yandex Object Storage"
  name        = "mpg-to-objstorage-transfer"
  source_id   = yandex_datatransfer_endpoint.mpg-source.id
  target_id   = local.objstorage_endpoint_id
  type        = "SNAPSHOT_ONLY" # Copying data from the source cluster
}
