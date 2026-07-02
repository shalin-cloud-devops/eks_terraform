# Declaring the cloud provider, it's version and the default region to be used for the resources in this configuration.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }
  backend "s3" {
    bucket         = "otel-eks-bucket"
    key            = "boutique_app/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "otel_table"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}


