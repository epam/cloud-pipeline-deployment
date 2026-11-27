/*
===============================================================================
  Platform-main role: attached to every EC2 node (master + application nodes)
===============================================================================
*/

data "aws_iam_policy" "AmazonSSMManagedInstanceCore" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "platform_main" {
  name                 = "${local.resource_name_prefix}-platform-main-role"
  permissions_boundary = var.iam_role_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "platform_main_ssm" {
  role       = aws_iam_role.platform_main.name
  policy_arn = data.aws_iam_policy.AmazonSSMManagedInstanceCore.arn
}

resource "aws_iam_policy" "platform_main" {
  name        = "${local.resource_name_prefix}-platform-main-policy"
  description = "Permissions for Cloud Pipeline cluster nodes in ${local.resource_name_prefix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Allow"
        Effect = "Allow"
        Action = [
          "s3:GetLifecycleConfiguration",
          "s3:GetBucketTagging",
          "s3:DeleteObjectVersion",
          "s3:GetObjectVersionTagging",
          "s3:ListBucketVersions",
          "s3:RestoreObject",
          "s3:CreateBucket",
          "s3:ListBucket",
          "s3:GetBucketPolicy",
          "s3:GetObjectAcl",
          "s3:AbortMultipartUpload",
          "s3:PutBucketTagging",
          "s3:PutLifecycleConfiguration",
          "s3:PutBucketAcl",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
          "s3:*Delete*",
          "s3:PutBucketVersioning",
          "s3:PutObjectAcl",
          "s3:DeleteObjectTagging",
          "s3:ListBucketMultipartUploads",
          "s3:PutObjectVersionTagging",
          "s3:DeleteObjectVersionTagging",
          "s3:GetBucketVersioning",
          "s3:PutBucketCORS",
          "s3:GetBucketAcl",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetBucketCORS",
          "s3:PutBucketPolicy",
          "s3:GetBucketLocation",
          "s3:GetObjectVersion",
          "s3:PutEncryptionConfiguration",
          "s3:GetEncryptionConfiguration",
          "s3:ListAllMyBuckets"
        ]
        Resource = ["arn:aws:s3:::*"]
      },
      {
        Sid      = "EFSAllow"
        Effect   = "Allow"
        Action   = ["elasticfilesystem:*"]
        Resource = ["arn:aws:elasticfilesystem:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:file-system/*"]
      },
      {
        Sid      = "FSxAllowFullControl"
        Effect   = "Allow"
        Action   = ["fsx:*"]
        Resource = "*"
      },
      {
        Sid    = "OtherAllow"
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:DeregisterImage",
          "kms:Decrypt",
          "ec2:DeleteSnapshot",
          "ec2:RequestSpotInstances",
          "ec2:DeleteTags",
          "elasticfilesystem:CreateFileSystem",
          "ec2:CancelSpotFleetRequests",
          "ec2:CreateKeyPair",
          "ec2:CreateImage",
          "ec2:RequestSpotFleet",
          "ec2:DeleteVolume",
          "ec2:DescribeNetworkInterfaces",
          "ec2:StartInstances",
          "kms:Encrypt",
          "ec2:CreateSnapshot",
          "kms:ReEncryptTo",
          "kms:DescribeKey",
          "ec2:ModifyInstanceMetadataOptions",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeInstanceStatus",
          "ec2:DetachVolume",
          "ec2:ReleaseAddress",
          "ec2:RebootInstances",
          "iam:GetRole",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:RegisterImage",
          "iam:ListRoles",
          "ec2:RunInstances",
          "ec2:StopInstances",
          "kms:ReEncryptFrom",
          "ec2:CreateVolume",
          "ec2:CreateNetworkInterface",
          "ec2:CancelSpotInstanceRequests",
          "ec2:Describe*",
          "kms:GenerateDataKey",
          "ec2:DescribeSubnets",
          "ec2:DeleteKeyPair",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      },
      {
        Sid      = "STSAllow"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [aws_iam_role.s3_via_sts.arn]
      },
      {
        Sid      = "AllowPassPlatformMainRole"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:PassRole"]
        Resource = aws_iam_role.platform_main.arn
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "platform_main" {
  role       = aws_iam_role.platform_main.name
  policy_arn = aws_iam_policy.platform_main.arn
}

resource "aws_iam_instance_profile" "platform_main" {
  name = "${local.resource_name_prefix}-platform-main-role"
  role = aws_iam_role.platform_main.name

  tags = local.tags
}

/*
===============================================================================
  S3-via-STS role: assumed by cp-api-srv to hand out temporary, scoped storage
  credentials to end users (CP_PREF_STORAGE_TEMP_CREDENTIALS_ROLE), and by
  S3 Batch Operations for the storage lifecycle service's archive/restore jobs
===============================================================================
*/

resource "aws_iam_role" "s3_via_sts" {
  name                 = "${local.resource_name_prefix}-s3-via-sts-role"
  permissions_boundary = var.iam_role_permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.platform_main.arn }
        Action    = "sts:AssumeRole"
      },
      {
        Effect    = "Allow"
        Principal = { Service = "batchoperations.s3.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_policy" "s3_via_sts" {
  name        = "${local.resource_name_prefix}-s3-via-sts-policy"
  description = "Permissions for Cloud Pipeline's S3-via-STS role in ${local.resource_name_prefix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
          "s3:DeleteObjectTagging",
          "s3:GetObjectVersionTagging",
          "s3:PutObjectVersionTagging",
          "s3:DeleteObjectVersionTagging",
          "s3:GetObjectVersion",
          "s3:DeleteObjectVersion",
          "s3:ListBucketVersions",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:PutObjectAcl",
          "s3:GetObjectAcl"
        ]
        Resource = ["arn:aws:s3:::*"]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "s3_via_sts" {
  role       = aws_iam_role.s3_via_sts.name
  policy_arn = aws_iam_policy.s3_via_sts.arn
}

resource "aws_iam_policy" "s3_batch_ops_submit" {
  name        = "${local.resource_name_prefix}-s3-batch-ops-submit-policy"
  description = "Permissions to submit S3 Batch Operations jobs for the storage lifecycle service in ${local.resource_name_prefix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BatchOps"
        Effect = "Allow"
        Action = [
          "s3:CreateJob",
          "s3:DescribeJob",
          "s3:UpdateJobStatus",
          "s3:UpdateJobPriority",
          "s3:ListJobs"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassS3ViaStsRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.s3_via_sts.arn
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "s3_batch_ops_submit" {
  role       = aws_iam_role.platform_main.name
  policy_arn = aws_iam_policy.s3_batch_ops_submit.arn
}
