data "terraform_remote_state" "zone" {
  backend = "s3"
  config = {
    bucket = "cabal-tf-backend"
    region = "us-east-1"
    key    = "development-bootstrap"
  }
}

