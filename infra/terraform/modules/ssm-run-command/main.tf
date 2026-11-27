# Runs var.commands on var.instance_id via SSM Run Command, in this same terraform apply -- no
# SSH/bastion/VPN connectivity to the node needed: traffic goes over the AWS API, using the
# AmazonSSMManagedInstanceCore permissions the node's instance profile is expected to already
# have. Requires the "aws" CLI to be installed and authenticated wherever `terraform apply` runs.
locals {
  # base64 has no quotes/backslashes in its alphabet, so this can be embedded in the rendered
  # script below and written out with a plain `echo | base64 -d` -- no shell-quoting of the
  # commands' own quotes/backslashes needed.
  params_b64 = base64encode(jsonencode({ commands = var.commands }))
}

resource "null_resource" "this" {
  triggers = merge(var.triggers, {
    instance_id   = var.instance_id
    commands_hash = md5(jsonencode(var.commands))
  })

  provisioner "local-exec" {
    command = templatefile("${path.module}/templates/run-command.sh.tpl", {
      region        = var.region
      instance_id   = var.instance_id
      params_b64    = local.params_b64
      timeout       = var.wait_timeout_seconds
      poll_interval = var.poll_interval_seconds
    })
  }
}
