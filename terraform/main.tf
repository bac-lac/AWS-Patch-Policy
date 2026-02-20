terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.33.0"
    }
  }

  backend "s3" {
    bucket      = "main-tfstate-c71307a3"
    region      = "ca-central-1"
    encrypt     = true
  }
}

provider "aws" {
  region  = "ca-central-1"
  assume_role {
    role_arn    = "${var.ROLE_ARN}"
    external_id = "${var.EXTERNAL_ID}"
  }
}

# SSM Patching
resource "aws_ssm_patch_baseline" "patch_baseline" {
  name            = "BAC-WindowsPatchBaseline-OS-Applications"
  operating_system = "WINDOWS"
  description     = "For the Windows Server operating system, approves all patches that are classified as CriticalUpdates or SecurityUpdates and that have an MSRC severity of Critical or Important. For Microsoft applications, approves all patches. Patches are auto-approved two days after release."

  approval_rule {
    approve_after_days = 2

    patch_filter {
      key    = "PATCH_SET"
      values = ["OS"]
    }

    patch_filter {
      key    = "MSRC_SEVERITY"
      values = ["Important", "Critical"]
    }
    
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["SecurityUpdates", "CriticalUpdates"]
    }
  }

  approval_rule {
    approve_after_days = 2

    patch_filter {
      key    = "PATCH_SET"
      values = ["APPLICATION"]
    }

    patch_filter {
      key    = "MSRC_SEVERITY"
      values = ["Important", "Critical"]
    }

    patch_filter {
      key    = "CLASSIFICATION"
      values = ["SecurityUpdates", "CriticalUpdates"]
    }
  }
}
locals {
  selected_patch_baselines_json = jsonencode({
    "WINDOWS" = {
      value       = aws_ssm_patch_baseline.patch_baseline.id
      label       = aws_ssm_patch_baseline.patch_baseline.name
      description = aws_ssm_patch_baseline.patch_baseline.description
      disabled    = false
    }
  })
  sat = var.ENV == "prod" ? 4 : 3
}

resource "aws_ssmquicksetup_configuration_manager" "ssm_qs_cm" {
  count       = var.PATCHGROUP_COUNT
  name        = "GoAnywhere-${var.ENV}-${count.index + 1}"
  description = "Patchgroup ${count.index + 1}"

  configuration_definition {
    local_deployment_administration_role_arn    = aws_iam_role.ssm_qs_admin_role.arn
    local_deployment_execution_role_name        = aws_iam_role.ssm_qs_exec_role.name

    type                                        = "AWSQuickSetupType-PatchPolicy"
    parameters = {
      ConfigurationOptionsInstallNextInterval   = "true"
      ConfigurationOptionsInstallValue          = "cron(0 ${count.index + 4} ? * SAT#${local.sat} *)"
      ConfigurationOptionsPatchOperation        = "ScanAndInstall"
      ConfigurationOptionsScanNextInterval      = "false"
      ConfigurationOptionsScanValue             = "cron(00 23 * * ? *)"
      IsPolicyAttachAllowed                     = "true"

      OutputBucketRegion                        = "ca-central-1"
      OutputLogEnableS3                         = "true"
      OutputS3BucketName                        = "${aws_s3_bucket.ssm_s3.id}"
      OutputS3KeyPrefix                         = "${var.ENV}-${count.index + 1}"

      PatchBaselineRegion                       = "ca-central-1"
      PatchBaselineUseDefault                   = "custom"
      PatchPolicyName                           = "Windows-VM-${var.ENV}-${count.index + 1}"

      RateControlConcurrency                    = "100%"
      RateControlErrorThreshold                 = "33%"

      RebootOption                              = "RebootIfNeeded"

      SelectedPatchBaselines                    = local.selected_patch_baselines_json

      TargetAccounts                            = "${var.ACCOUNT}"
      TargetRegions                             = "ca-central-1"
      TargetTagKey                              = "PatchGroup"
      TargetTagValue                            = "${count.index + 1}"
      TargetType                                = "Tags"
    }
  }
  depends_on  = [aws_iam_role_policy_attachment.ssm_qs_exec_attach, aws_iam_role_policy_attachment.qs_admin_attach]
}

# SSM S3 Bucket
resource "aws_s3_bucket" "ssm_s3" {
  bucket        = "ssm-patch-policy-${var.ENV}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "ssm_versioning" {
  bucket = aws_s3_bucket.ssm_s3.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "ssm_public_access_block" {
  bucket = aws_s3_bucket.ssm_s3.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_encryption" {
  bucket = aws_s3_bucket.ssm_s3.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# SSM QUICKSETUP ROLES
data "aws_iam_policy_document" "qs_exec_assume_role" {
  statement {
    effect        = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ssm_qs_admin_role.arn]
    }
    actions       = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ssm_qs_exec_role" {
  name               = "AWS-QuickSetup-VM-LocalExecutionRole-${var.ENV}"
  assume_role_policy = data.aws_iam_policy_document.qs_exec_assume_role.json
  description        = "Local Execution role for AWS SSM Quick Setup (VM)"
}

resource "aws_iam_role_policy_attachment" "ssm_qs_exec_attach" {
  role       = aws_iam_role.ssm_qs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSQuickSetupPatchPolicyDeploymentRolePolicy"
}

resource "aws_iam_role" "ssm_qs_admin_role" {
  name        = "AWS-QuickSetup-VM-LocalAdministrationRole-${var.ENV}"
  description = "Local Admin role for AWS SSM Quick Setup (VM)"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        "Effect": "Allow",
        "Principal": {
            "Service": "cloudformation.amazonaws.com"
        },
        "Action": "sts:AssumeRole",
        "Condition": {
            "StringEquals": {
                "aws:SourceAccount": "${var.ACCOUNT}"
            },
            "StringLike": {
                "aws:SourceArn": "arn:aws:cloudformation:*:${var.ACCOUNT}:stackset/AWS-QuickSetup-*"
            }
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "ssm_qs_admin_permissions" {
  version     = "2012-10-17"
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.ssm_qs_exec_role.arn]
    effect    = "Allow"
  }
}

resource "aws_iam_policy" "qs_admin_policy" {
  name        = "AWS-QuickSetup-VM-LocalAdministrationRole-policy-${var.ENV}"
  description = "Permissions for Quick Setup local admin role"
  policy      = data.aws_iam_policy_document.ssm_qs_admin_permissions.json
}

resource "aws_iam_role_policy_attachment" "qs_admin_attach" {
  role       = aws_iam_role.ssm_qs_admin_role.name
  policy_arn = aws_iam_policy.qs_admin_policy.arn
}

##### SSM S3 bucket roles and policies #####
data "aws_iam_policy_document" "patchpolicy_get_object" {
  statement {
    sid     = "AllowGetObjectFromQuickSetupPatchPolicyBuckets"
    effect  = "Allow"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::aws-quicksetup-patchpolicy-*/*",
    ]
  }
}

resource "aws_iam_policy" "s3_get_object_policy" {
  name        = "aws-quicksetup-patchpolicy-baselineoverrides-s3-${var.ENV}"
  description = "Allow GetObject on aws-quicksetup-patchpolicy-* buckets"
  policy      = data.aws_iam_policy_document.patchpolicy_get_object.json
}

data "aws_iam_policy_document" "ssm_s3_permissions" {
  version   = "2012-10-17"

  statement {
    sid     = "AllowOnlySSMRolesToReadWrite"
    effect  = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.ssm_s3.arn}/*"
    ]

    principals {
      type        = "AWS"
      identifiers = ["${aws_iam_role.ssm_role.arn}"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [
      "${aws_s3_bucket.ssm_s3.arn}",
      "${aws_s3_bucket.ssm_s3.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "ssm_s3_policy" {
  bucket = aws_s3_bucket.ssm_s3.id
  policy = data.aws_iam_policy_document.ssm_s3_permissions.json
}

variable "ACCOUNT" {
  type = string  
  sensitive = true
  description = "The account number."
  default = "ACCOUNT"
}

variable "ENV" {
  type = string
  description = "The environment in which to deploy the solution."
  default = "dev"
}

variable "EXTERNAL_ID" {
  type = string  
  sensitive = true
  description = "External ID of the automation account role."
  default = "EXTERNAL_ID"
}

variable "PATCHGROUP_COUNT" {
  type = number
  description = "Number of patch groups to create."
  default = 1
}

variable "ROLE_ARN" {
  type = string  
  sensitive = true
  description = "ARN of the role used by terraform."
  default = "ARN"
}