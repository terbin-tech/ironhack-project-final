terraform {
  required_version = "~> 1.17"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }

  # Partial configuration: the bucket name holds the account ID (backend.hcl.example).
  backend "s3" {}
}

data "terraform_remote_state" "main" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "main/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.main.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.main.outputs.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.main.outputs.cluster_name, "--region", "us-east-1"]
  }
}
