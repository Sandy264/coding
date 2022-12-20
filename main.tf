terraform {

  required_version = ">= 0.14.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      version = "3.67.0"
    }
  }

  # instead of state stored in remote gcs bucket, use local fileystem
  #backend "gcs" {
  #  bucket  = "${var.project}-terraformstate"
  #  prefix  = "default"
  #}

}

provider "google" {
      # do not need json key if working using: gcloud auth application-default login
      credentials = file("tf-creator.json")

      project     = var.project
      region      = var.region
      zone        = var.zone
}


resource "google_compute_network" "myvpc" {
  name = "wg-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "web_subnetwork" {
  provider      = google-beta

  name          = "wg-subnetwork"
  ip_cidr_range = var.cidr_block
  region        = var.region
  network       = google_compute_network.myvpc.name

  #https://registry.terraform.io/providers/hashicorp/google-beta/latest/docs/resources/compute_subnetwork
  #purpose       = "PUBLIC"

  depends_on = [google_compute_network.myvpc]
}
resource "google_compute_subnetwork" "app_subnetwork" {
  provider      = google-beta

  name          = "private-subnetwork"
  ip_cidr_range = var.private_cidr_block
  region        = var.region
  network       = google_compute_network.myvpc.name
  purpose       = "PRIVATE"

  depends_on = [google_compute_network.myvpc]
}

resource "google_compute_subnetwork" "db_subnetwork" {
  provider      = google-beta

  name          = "db-subnetwork"
  ip_cidr_range = var._cidr_block
  region        = var.region
  network       = google_compute_network.myvpc.name
  purpose       = "db"

  depends_on = [google_compute_network.myvpc]
}

# create a public ip for nat service
resource "google_compute_address" "nat-ip" {
  name = "nat-ip"
  project = var.project
  region  = var.region
}
# create a nat to allow private instances connect to internet
resource "google_compute_router" "nat-router" {
  name = "nat-router"
  network = google_compute_network.myvpc.name
}
resource "google_compute_router_nat" "nat-gateway" {
  name = "nat-gateway"
  router = google_compute_router.nat-router.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips = [ google_compute_address.nat-ip.self_link ]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS" #"ALL_SUBNETWORKS_ALL_IP_RANGES" 
  subnetwork { 
     name = google_compute_subnetwork.app_subnetwork.id
     source_ip_ranges_to_nat = [ var.private_cidr_block ] # "ALL_IP_RANGES"
  }
  subnetwork { 
     name = google_compute_subnetwork.db_subnetwork.id
     source_ip_ranges_to_nat = [ var.db_cidr_block ] # "ALL_IP_RANGES"
  }
  depends_on = [ google_compute_address.nat-ip ]
}


resource "google_compute_firewall" "web-firewall" {
  depends_on = [google_compute_subnetwork.web_subnetwork]

  name    = "default-allow-wg"
  network = "myvpc"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  allow {
    protocol = "icmp"
  }

  // Allow traffic from everywhere to instances with tag
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "app-firewall" {
  depends_on = [google_compute_subnetwork.app_subnetwork]

  name    = "default-allow-web"
  network = "wg-network"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = var.cidr_block
}

resource "google_compute_firewall" "db-firewall" {
  depends_on = [google_compute_subnetwork.app_subnetwork]

  name    = "default-allow-web"
  network = "wg-network"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = var.private_cidr_block
}


##############################################################

resource "google_compute_instance" "webserver" {
  name         = "webserver"
  machine_type = var.machine_type
  zone         = var.zone
  can_ip_forward = true

  #depends_on = [google_compute_network.wg_network]
  depends_on = [google_compute_subnetwork.web_subnetwork]

  boot_disk {
    initialize_params {
      image = var.os_image
      type = "pd-ssd"
      size = "40"
    }
  }

  network_interface {
    network = "myvpc"
    subnetwork = "web-subnetwork"

    access_config {
      // empty block means ephemeral external IP
    }
  }


  // using ssh key attached directly to vm (not ssh key in project level metadata)  
  metadata = {
    ssh-keys = "ubuntu:${file("../ansible_rsa.pub")}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update --allow-unauthenticated -q"
    ]
    connection {
      type = "ssh"
      #timeout = 200
      user = "ubuntu"
      host = self.network_interface.0.access_config.0.nat_ip
      private_key = file(privatekey)
    }
  }

  // Apply the firewall rule to allow external IPs to access this instance
  tags = ["web-server"]
}

resource "google_compute_instance" "appserver" {
  name         = "appserver"
  machine_type = var.machine_type
  zone         = var.zone
  can_ip_forward = true

  #depends_on = [google_compute_network.wg_network]
  depends_on = [google_compute_subnetwork.app_subnetwork]

  boot_disk {
    initialize_params {
      image = var.os_image
      type = "pd-ssd"
      size = "40"
    }
  }

  network_interface {
    network = "myvpc"
    subnetwork = "app-subnetwork"

  }


  // using ssh key attached directly to vm (not ssh key in project level metadata)  
  metadata = {
    ssh-keys = "ubuntu:${file("../ansible_rsa.pub")}"
  }

  // Apply the firewall rule to allow external IPs to access this instance
  tags = ["app-server"]
}