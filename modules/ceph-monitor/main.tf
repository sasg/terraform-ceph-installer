#------------------------------------------------------------------------------------
# Get a list of Availability Domains
#------------------------------------------------------------------------------------
data "oci_identity_availability_domains" "ADs" {
  compartment_id = "${var.tenancy_ocid}"
}

#------------------------------------------------------------------------------------
# Get the OCID of the OS image to use
#------------------------------------------------------------------------------------
data "oci_core_images" "image_ocid" {
  compartment_id = "${var.compartment_ocid}"
  display_name = "${var.instance_os}"
}

#------------------------------------------------------------------------------------
# Create Ceph Monitor Server Instances
#------------------------------------------------------------------------------------
resource "oci_core_instance" "ceph_monitors" {
  count = "${var.instance_count}"
  availability_domain =  "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.availability_domain_index_list[count.index] - 1],"name")}"
  compartment_id = "${var.compartment_ocid}"
  display_name = "${var.hostname_prefix}-${count.index}"
  hostname_label = "${var.hostname_prefix}-${count.index}"
  shape = "${var.shape}"
  subnet_id = "${var.subnet_id_list[var.availability_domain_index_list[count.index] - 1]}"
  source_details {
    source_type = "image"
    source_id = "${lookup(data.oci_core_images.image_ocid.images[0], "id")}"
  }
  metadata {
    ssh_authorized_keys = "${file(var.ssh_public_key_file)}"
  }
  connection {
    host = "${self.private_ip}"
    type = "ssh"
    user = "${var.ssh_username}"
    private_key = "${file(var.ssh_private_key_file)}"
  }
  provisioner "remote-exec" {
    inline = [
      " mkdir ~/${var.scripts_dst_directory}",
    ]
  }
  provisioner "file" {
    source = "${var.scripts_src_directory}/ceph.config"
    destination = "~/${var.scripts_dst_directory}/ceph.config"
  }
  provisioner "file" {
    source = "${var.scripts_src_directory}/vm_setup.sh"
    destination = "~/${var.scripts_dst_directory}/vm_setup.sh"
  }
  provisioner "file" {
    source = "${var.scripts_src_directory}/yum_repo_setup.sh"
    destination = "~/${var.scripts_dst_directory}/yum_repo_setup.sh"
  }
  provisioner "file" {
    source = "${var.scripts_src_directory}/ceph_yum_repo"
    destination = "~/${var.scripts_dst_directory}/ceph_yum_repo"
  }
  provisioner "file" {
    source = "${var.scripts_src_directory}/ceph_firewall_setup.sh"
    destination = "~/${var.scripts_dst_directory}/ceph_firewall_setup.sh"
  }
  timeouts {
    create = "${var.instance_create_timeout}"
  }
}

#------------------------------------------------------------------------------------
# Setup the VM
#------------------------------------------------------------------------------------
resource "null_resource" "vm_setup" {
  depends_on = ["oci_core_instance.ceph_monitors"]
  count = "${var.instance_count}"
  provisioner "remote-exec" {
    connection {
      agent = false
      timeout = "30m"
      host = "${element(oci_core_instance.ceph_monitors.*.private_ip, count.index)}"
      user = "${var.ssh_username}"
      private_key = "${file(var.ssh_private_key_file)}"
    }
    inline = [
      "chmod +x ~/${var.scripts_dst_directory}/vm_setup.sh",
      "chmod +x ~/${var.scripts_dst_directory}/yum_repo_setup.sh",
      "chmod +x ~/${var.scripts_dst_directory}/ceph_firewall_setup.sh",
      "cd ${var.scripts_dst_directory}",
      "./vm_setup.sh monitor"
    ]
  }
}

#------------------------------------------------------------------------------------
# Setup Yum Repository
#------------------------------------------------------------------------------------
resource "null_resource" "setup" {
  depends_on = ["null_resource.vm_setup"]
  count = "${var.instance_count}"
  provisioner "remote-exec" {
    connection {
      agent = false
      timeout = "30m"
      host = "${element(oci_core_instance.ceph_monitors.*.private_ip, count.index)}"
      user = "${var.ssh_username}"
      private_key = "${file(var.ssh_private_key_file)}"
    }
    inline = [
      "cd ${var.scripts_dst_directory}",
      "./yum_repo_setup.sh",
      "./ceph_firewall_setup.sh monitor"
    ]
  }
}

#------------------------------------------------------------------------------------
# Passwordless SSH Setup
# - Get the ssh key from the Ceph Deployer Instance and install on the Monitors
#------------------------------------------------------------------------------------
resource "null_resource" "wait_for_deployer_deploy" {
  provisioner "local-exec" {
    command = "echo 'Waited for Deployer Ceph Deployment (${var.deployer_deploy}) to complete'"
  }
}

resource "null_resource" "copy_key" {
  depends_on = ["null_resource.setup", "null_resource.wait_for_deployer_deploy"]
  count = "${var.instance_count}"
  provisioner "local-exec" {
    command = "${var.scripts_src_directory}/install_ssh_key.sh ${var.ceph_deployer_ip} ${element(oci_core_instance.ceph_monitors.*.private_ip, count.index)}"
  }
}

resource "null_resource" "add_to_deployer_known_hosts" {
  depends_on = ["null_resource.copy_key"]
  count = "${var.instance_count}"
  provisioner "remote-exec" {
    connection {
      agent = false
      timeout = "30m"
      host = "${var.ceph_deployer_ip}"
      user = "${var.ssh_username}"
      private_key = "${file(var.ssh_private_key_file)}"
    }
    inline = [
      "cd ${var.scripts_dst_directory}",
      "./add_to_etc_hosts.sh ${element(oci_core_instance.ceph_monitors.*.private_ip, count.index)} ${element(oci_core_instance.ceph_monitors.*.hostname_label, count.index)}",
      "./add_to_known_hosts.sh ${element(oci_core_instance.ceph_monitors.*.private_ip, count.index)} ${element(oci_core_instance.ceph_monitors.*.hostname_label, count.index)}",
    ]
  }
}

#------------------------------------------------------------------------------------
# Create a new cluster
#------------------------------------------------------------------------------------
resource "null_resource" "create_new_cluster" {
  depends_on = ["null_resource.add_to_deployer_known_hosts", "null_resource.wait_for_deployer_deploy"]
  provisioner "remote-exec" {
    connection {
      agent = false
      timeout = "30m"
      host = "${var.ceph_deployer_ip}"
      user = "${var.ssh_username}"
      private_key = "${file(var.ssh_private_key_file)}"
    }
    inline = [
      "cd ${var.scripts_dst_directory}",
       "./ceph_new_cluster.sh ${join(" ", oci_core_instance.ceph_monitors.*.hostname_label)}"
    ]
  }
}
