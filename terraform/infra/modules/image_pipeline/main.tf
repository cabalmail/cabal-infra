/**
*
* # Status
*
* On hold pending resolution of [issue #16839](https://github.com/hashicorp/terraform-provider-aws/issues/16839) which will add Terraform support for building docker container images.
*
* Code to date adapted from [this sample](https://github.com/aws-samples/amazon-ec2-image-builder-samples/blob/master/CloudFormation/Docker/amazon-linux-2-with-helloworld/amazon-linux-2-container-image.yml).
*
* Based on https://github.com/aws-samples/amazon-ec2-image-builder-samples/blob/master/CloudFormation/Docker/amazon-linux-2-with-helloworld/amazon-linux-2-container-image.yml
*
*/

resource "aws_ecr_repository" "cabal_ecr_repo" {
  name                 = "cabal_container_repository"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "cabal_infra_config" {
  instance_profile_name         = aws_iam_instance_profile.cabal_instance_profile.name
  instance_types                = ["t2.micro"]
  name                          = "cabal_base_image"
  terminate_instance_on_failure = true

  logging {
    s3_logs {
      s3_bucket_name = aws_s3_bucket.cabal_image_builder_log_bucket.id
      s3_key_prefix  = "imabebuilder_logs"
    }
  }
}

resource "aws_imagebuilder_component" "cabal_component" {
  data = yamlencode({
    phases = [{
      name = "build"
      steps = [{
        action = "ExecuteBash"
        inputs = {
          commands = ["echo 'hello world'"]
        }
        name      = "example"
        onFailure = "Continue"
      }]
    }]
    schemaVersion = 1.0
  })
  name     = "cabal_hello_world"
  platform = "Linux"
  version  = "1.0.0"
}

resource "aws_imagebuilder_image_recipe" "cabal_recipe" {
  container_type = "DOCKER"
  component {
    component_arn = aws_imagebuilder_component.cabal_component.arn
  }
  name           = "cabal_recipe"
  parent_image   = "arn:${data.aws_partition.current.partition}:imagebuilder:${data.aws_region.current.name}:aws:image/amazon-linux-2-x86/x.x.x"
  version        = "1.0.0"
}

# resource "aws_imagebuilder_image_pipeline" "cabal_image_pipeline" {
#   image_recipe_arn                 = aws_imagebuilder_image_recipe.example.arn
#   infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.example.arn
#   name                             = "example"

#   schedule {
#     schedule_expression = "cron(0 0 * * ? *)"
#   }
# }
