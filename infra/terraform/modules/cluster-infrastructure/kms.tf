module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.2"

  aliases               = [local.resource_name_prefix]
  description           = "${local.resource_name_prefix} Cloud Pipeline encryption key"
  enable_default_policy = true
  enable_key_rotation   = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Default"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowUseOfTheKey"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_iam_role.platform_main.arn,
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAttachmentOfPersistentResources"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_iam_role.platform_main.arn,
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
          ]
        }
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      }
    ]
  })

  tags = local.tags
}
