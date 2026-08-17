data "amazon-ami" "al2023" {
  filters = {
    virtualization-type = "hvm"
    name                = "al2023-ami-2023.*-kernel-6.18-x86_64"
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.region
}
