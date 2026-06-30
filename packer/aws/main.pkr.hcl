packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "this" {
  vpc_id              = var.vpc_id
  subnet_id           = var.subnet_id
  ami_name            = "${var.ami_name_prefix}-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  instance_type       = var.instance_type
  region              = var.region
  source_ami          = data.amazon-ami.al2023.id
  security_group_id   = var.security_group_id
  iam_instance_profile = var.iam_instance_profile

  # Provisioning connection parameters
  communicator  = "ssh"
  ssh_username  = "ec2-user"
  ssh_timeout   = "10m"
  ssh_interface = var.ssh_interface
}

build {
  name = "prepare_kubernetes"
  sources = [
    "source.amazon-ebs.this"
  ]

  provisioner "shell" {
    inline = ["sudo yum install -y amazon-efs-utils lustre-client"]
  }

  provisioner "shell" {
    execute_command   = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{.Path}}"
    script            = "${path.root}/../common/scripts/install_prerequsites.sh"
    expect_disconnect = true
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir /cp_temp",
      "sudo chmod -R 777 /cp_temp"
    ]
  }

  provisioner "file" {
    sources     = ["../common/resources/config/canal.yaml.raw", "../common/resources/config/kubeadm-init-config.yaml.raw"]
    destination = "/cp_temp/"
  }
  provisioner "file" {
    source      = "../common/scripts/patch-kube-dns.sh"
    destination = "/cp_temp/"
  }
  provisioner "file" {
    source      = "../../helm"
    destination = "/cp_temp/"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /var/lib/cloud-pipeline/deploy/k8s-bootstrap",
      "sudo cp -f /cp_temp/kubeadm-init-config.yaml.raw /cp_temp/canal.yaml.raw /var/lib/cloud-pipeline/deploy/k8s-bootstrap/",
      "sudo cp -f /cp_temp/patch-kube-dns.sh /var/lib/cloud-pipeline/deploy/k8s-bootstrap/patch-kube-dns.sh",
      "sudo chmod 755 /var/lib/cloud-pipeline/deploy/k8s-bootstrap/patch-kube-dns.sh",
      "sudo mv /cp_temp/helm /var/lib/cloud-pipeline/deploy/helm",
      "echo '${var.cloud_pipeline_build_version}' | sudo tee /var/lib/cloud-pipeline/deploy/helm/CP_BUILD_VERSION.txt",
      "sudo chmod -R 777 /var/lib/cloud-pipeline/deploy",
      "sudo rm -rf /cp_temp"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "CP_CLOUD_PIPELINE_NODE_REGION=${var.region}",
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{.Path}}"
    script          = "${path.root}/../common/scripts/install_kubernetes.sh"
    pause_before    = "30s"
  }
}

