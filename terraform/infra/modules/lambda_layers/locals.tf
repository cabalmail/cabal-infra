locals {
  lambda_layers = {
    python = {
      runtime = "python3.9"
    },
    nodejs = {
      runtime = "nodejs14.x"
    }
  }
}