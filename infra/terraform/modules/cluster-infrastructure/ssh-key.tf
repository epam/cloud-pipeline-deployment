# Generated only when the caller does not supply an existing key pair name.
resource "tls_private_key" "generated" {
  count = var.key_name == null ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  count = var.key_name == null ? 1 : 0

  key_name   = "${local.resource_name_prefix}-key"
  public_key = trimspace(tls_private_key.generated[0].public_key_openssh)

  tags = local.tags
}
