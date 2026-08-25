terraform {
  required_version = ">= 1.10"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "6.51.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}
