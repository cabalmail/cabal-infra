config {
  plugin_dir = "~/.tflint.d/plugins"
}

plugin "aws" {
    enabled = true
    version = "0.20.0"
    source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
