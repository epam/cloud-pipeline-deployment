packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
    git = {
      version = ">= 0.6.2"
      source  = "github.com/ethanmdavidson/git"
    }
  }
}

data "git-commit" "cwd-head" {}

locals {
  git_sha = substr(data.git-commit.cwd-head.hash, 0, 8)
}

source "amazon-ebs" "this" {
  vpc_id               = var.vpc_id
  subnet_id            = var.subnet_id
  ami_name             = "${var.ami_name_prefix}-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  instance_type        = var.instance_type
  region               = var.region
  source_ami           = data.amazon-ami.al2023.id
  security_group_id    = var.security_group_id
  iam_instance_profile = var.iam_instance_profile

  # Provisioning connection parameters
  communicator  = "ssh"
  ssh_username  = "ec2-user"
  ssh_timeout   = "10m"
  ssh_interface = var.ssh_interface
  tags = {
    OS_Version    = "amzn2023"
    Base_AMI_Name = "{{ .SourceAMIName }}"
    Type          = "application-node"
    SHA           = local.git_sha
  }
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
    inline = ["echo 'CLOUD_PIPELINE_DISTRO_DIR=${var.cloud_pipeline_deploy_dir_path}' | sudo tee -a /etc/environment"]
  }

  provisioner "shell" {
    environment_vars = [
      "CLOUD_PIPELINE_DISTRO_DIR=${var.cloud_pipeline_deploy_dir_path}",
      "DOCKER_DATA_ROOT=${var.docker_data_root}",
    ]
    execute_command   = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{.Path}}"
    script            = "${path.root}/../common/scripts/install_prerequsites.sh"
    expect_disconnect = true
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /cp_temp/helm",
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
    source      = "../../helm/prerequisites"
    destination = "/cp_temp/helm/"
  }
  provisioner "file" {
    source      = "../../helm/README.md"
    destination = "/cp_temp/helm/README.md"
  }
  provisioner "file" {
    source      = "../../helm/values.yaml"
    destination = "/cp_temp/helm/values.yaml"
  }

  provisioner "shell" {
    environment_vars = [
      "CP_DEPLOYMENT_COMMIT=${var.cloud_pipeline_deployment_commit}",
    ]
    inline = [
      "COMMIT=$${CP_DEPLOYMENT_COMMIT:-$(git ls-remote https://github.com/epam/cloud-pipeline-deployment.git refs/heads/main | cut -f1)}",
      "echo 'helmfiles:' > /cp_temp/helm/helmfile.yaml",
      "echo \"  - path: 'git::https://github.com/epam/cloud-pipeline-deployment.git@helm/helmfile.yaml.gotmpl?ref=$COMMIT'\" >> /cp_temp/helm/helmfile.yaml"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p ${var.cloud_pipeline_deploy_dir_path}/k8s-bootstrap",
      "sudo cp -f /cp_temp/kubeadm-init-config.yaml.raw /cp_temp/canal.yaml.raw ${var.cloud_pipeline_deploy_dir_path}/k8s-bootstrap/",
      "sudo cp -f /cp_temp/patch-kube-dns.sh ${var.cloud_pipeline_deploy_dir_path}/k8s-bootstrap/patch-kube-dns.sh",
      "sudo chmod 755 ${var.cloud_pipeline_deploy_dir_path}/k8s-bootstrap/patch-kube-dns.sh",
      "sudo mv /cp_temp/helm ${var.cloud_pipeline_deploy_dir_path}/helm",
      "echo '${var.cloud_pipeline_build_version}' | sudo tee ${var.cloud_pipeline_deploy_dir_path}/helm/CP_BUILD_VERSION.txt",
      "sudo chmod -R 777 ${var.cloud_pipeline_deploy_dir_path}",
      "sudo rm -rf /cp_temp"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "CP_CLOUD_PIPELINE_NODE_REGION=${var.region}",
      "CLOUD_PIPELINE_DISTRO_DIR=${var.cloud_pipeline_deploy_dir_path}",
      "DOCKER_DATA_ROOT=${var.docker_data_root}",
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{.Path}}"
    script          = "${path.root}/../common/scripts/install_kubernetes.sh"
    pause_before    = "30s"
  }
}

