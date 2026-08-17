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

source "amazon-ebs" "cpu" {
  vpc_id               = var.vpc_id
  subnet_id            = var.subnet_id
  ami_name             = "${var.ami_name_prefix}-cpu-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  instance_type        = var.cpu_instance_type
  region               = var.region
  source_ami           = data.amazon-ami.al2023.id
  security_group_id    = var.security_group_id
  iam_instance_profile = var.iam_instance_profile
  communicator         = "ssh"
  ssh_username         = "ec2-user"
  ssh_timeout          = "10m"
  ssh_interface        = var.ssh_interface
  tags = {
    OS_Version    = "amzn2023"
    Base_AMI_Name = "{{ .SourceAMIName }}"
    Type          = "cpu"
    SHA           = local.git_sha
  }
}

source "amazon-ebs" "gpu" {
  vpc_id               = var.vpc_id
  subnet_id            = var.subnet_id
  ami_name             = "${var.ami_name_prefix}-gpu-${formatdate("YYYY-MM-DD-hhmmss", timestamp())}"
  instance_type        = var.gpu_instance_type
  region               = var.region
  source_ami           = data.amazon-ami.al2023.id
  security_group_id    = var.security_group_id
  iam_instance_profile = var.iam_instance_profile
  communicator         = "ssh"
  ssh_username         = "ec2-user"
  ssh_timeout          = "10m"
  ssh_interface        = var.ssh_interface
  tags = {
    OS_Version    = "amzn2023"
    Base_AMI_Name = "{{ .SourceAMIName }}"
    Type          = "gpu"
    SHA           = local.git_sha
  }
}

build {
  name    = "cloud-pipeline-worker"
  sources = ["source.amazon-ebs.cpu", "source.amazon-ebs.gpu"]

  provisioner "shell" {
    only            = ["amazon-ebs.cpu"]
    execute_command = "chmod +x {{ .Path }}; sudo {{.Path}}"
    script          = "${path.root}/cpu/install-deps.sh"
  }

  provisioner "shell" {
    only            = ["amazon-ebs.gpu"]
    execute_command = "chmod +x {{ .Path }}; sudo {{.Path}}"
    script          = "${path.root}/gpu/install-deps.sh"
  }
}
