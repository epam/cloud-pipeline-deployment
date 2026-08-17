# Worker node AMI

Builds Amazon Linux 2023 AMIs for Cloud Pipeline worker nodes (CPU and GPU variants).

## Prerequisites

- [Packer](https://developer.hashicorp.com/packer/install) >= 1.10
- AWS credentials configured (environment variables or instance profile)
- IAM instance profile that grants `AmazonSSMManagedInstanceCore` if using `ssh_interface = "session_manager"`

## Configuration

Fill in the required values in `variables.auto.pkrvars.hcl`:

```hcl
vpc_id            = "vpc-xxxxxxxx"
subnet_id         = "subnet-xxxxxxxx"
security_group_id = "sg-xxxxxxxx"
region            = "us-east-1"
```

## Build

```bash
cd packer/aws/worker
packer init .

# Build both CPU and GPU AMIs
packer build .

# Build CPU only
packer build -only='*.cpu' .

# Build GPU only
packer build -only='*.gpu' .
```
