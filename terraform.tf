terraform {
    required_providers {
      aws = {
        source = "hashicorp/aws"
      }
    }
}

provider "aws" {
    region = "ap-northeast-2"
}

provider "aws" {
    alias = "singapore"
    region = "ap-southeast-1"
}