provider "aws" {
  region = var.aws_region
}

module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = var.bucket_name
  acl    = "private"


  force_destroy = true

  versioning = {
    enabled = false
  }

  attach_policy = true
  policy        = data.aws_iam_policy_document.bucket_policy.json

  tags = {
    ManagedBy = "Terraform"
  }

}

resource "aws_s3_bucket_website_configuration" "s3_bucket" {
  bucket = var.bucket_name

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }

}

data "aws_iam_policy_document" "bucket_policy" {

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.s3_bucket.s3_bucket_arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.my_origin_access_identity.iam_arn]
    }
  }


}



# Create a json file for CodePipeline's policy
data "aws_iam_policy_document" "codepipeline_assume_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}


# Create a role for CodePipeline
resource "aws_iam_role" "codepipeline_role" {
  name               = "${var.bucket_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_policy.json
}


# Create a json file for CodePipeline's policy needed to use GitHub and CodeBuild
data "aws_iam_policy_document" "codepipeline_policy" {

  statement {

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject"
    ]

    resources = ["${module.s3_bucket.s3_bucket_arn}",
    "${module.s3_bucket.s3_bucket_arn}/*"]
  }

  statement {

    effect = "Allow"

    actions = [
      "codestar-connections:UseConnection"
    ]

    resources = ["${aws_codestarconnections_connection.GitHub.arn}"]
  }

  statement {

    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild"
    ]

    resources = ["*"]

  }

}



# CodePipeline policy needed to use GitHub and CodeBuild
resource "aws_iam_role_policy" "attach_codepipeline_policy" {

  name = "${var.bucket_name}-codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = data.aws_iam_policy_document.codepipeline_policy.json

}


# Create a json file for CodeBuild's policy
data "aws_iam_policy_document" "CodeBuild_assume_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

# Create a role for CodeBuild
resource "aws_iam_role" "codebuild_assume_role" {
  name = "${var.bucket_name}-codebuild-role"

  assume_role_policy = data.aws_iam_policy_document.CodeBuild_assume_policy.json

}


# Create a json file for CodeBuild's policy
data "aws_iam_policy_document" "codebuild_policy" {

  statement {

    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
      "s3:DeleteObject",
      "cloudfront:CreateInvalidation"
    ]

    resources = ["${module.s3_bucket.s3_bucket_arn}",
    "${module.s3_bucket.s3_bucket_arn}/*"]
  }

  statement {

    effect = "Allow"

    actions = [
      "codebuild:*",
      "cloudfront:CreateInvalidation"
    ]

    resources = ["${aws_codebuild_project.build_project.id}"]
  }

  statement {

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "cloudfront:CreateInvalidation"
    ]

    resources = ["*"]

  }

}


# Create CodeBuild policy
resource "aws_iam_role_policy" "attach_codebuild_policy" {
  name = "${var.bucket_name}-codebuild-policy"
  role = aws_iam_role.codebuild_assume_role.id

  policy = data.aws_iam_policy_document.codebuild_policy.json

}


data "local_file" "buildspec_local" {
  filename = "./buildspec.yml"
}

# Create CodeBuild project
resource "aws_codebuild_project" "build_project" {
  name          = "${var.aws_codebuild_project_name}-website-build"
  description   = "CodeBuild project for ${var.bucket_name}"
  service_role  = aws_iam_role.codebuild_assume_role.arn
  build_timeout = "300"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "DISTRIBUITION_ID"
      value = aws_cloudfront_distribution.s3_distribution.id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = data.local_file.buildspec_local.content
  }

  tags = {
    ManagedBy = "Terraform"
  }
}


resource "aws_codestarconnections_connection" "GitHub" {
  name          = "GitHub-connection"
  provider_type = "GitHub"
  tags = {
    ManagedBy = "Terraform"
  }
}

# Create CodePipeline
resource "aws_codepipeline" "codepipeline" {

  name     = "${var.bucket_name}-codepipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {

    location = module.s3_bucket.s3_bucket_id
    type     = "S3"
  }

  stage {

    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.GitHub.arn
        FullRepositoryId = "aolmedof/website"
        BranchName       = "main"
      }
    }
  }


  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "S3"
      input_artifacts = ["SourceArtifact"]
      version         = "1"

      configuration = {
        BucketName = var.bucket_name
        Extract    = "true"
      }
    }
  }

  stage {
    name = "Invalidate"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["OutputArtifact"]
      version          = "1"


      configuration = {
        ProjectName = aws_codebuild_project.build_project.name
      }
    }
  }

  tags = {
    ManagedBy = "Terraform"
  }

}

locals {
  s3_origin_id = "s3_one"
}

resource "aws_cloudfront_origin_access_identity" "my_origin_access_identity" {
  comment = "MyCloudFront"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = "${var.bucket_name}.s3.amazonaws.com"
    origin_id   = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.my_origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "My CloudFront"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  ordered_cache_behavior {
    path_pattern     = "/index_files/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}
