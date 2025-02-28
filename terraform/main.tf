provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway     = "http://localstack:4566"
    lambda         = "http://localstack:4566"
    cloudwatch     = "http://localstack:4566"
    iam            = "http://localstack:4566"
    logs           = "http://localstack:4566"
    s3             = "http://localstack:4566"
  }
}

data "archive_file" "process_readings_lambda" {
  type        = "zip"
  source_dir  = "/lambda/process_readings"
  output_path = "/terraform/process_readings.zip"
}

data "archive_file" "query_metrics_lambda" {
  type        = "zip"
  source_dir  = "/lambda/query_metrics"
  output_path = "/terraform/query_metrics.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_logging" {
  name        = "lambda-logging"
  description = "IAM policy for logging from a Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}

resource "aws_lambda_function" "process_readings" {
  function_name    = "process-license-plate-readings"
  filename         = data.archive_file.process_readings_lambda.output_path
  runtime          = "python3.9"
  handler          = "app.lambda_handler"
  source_code_hash = data.archive_file.process_readings_lambda.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  timeout          = 30

  environment {
    variables = {
      DB_HOST     = "postgres"
      DB_NAME     = "licenseplate_db"
      DB_USER     = "postgres"
      DB_PASSWORD = "postgres"
      DB_PORT     = "5432"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs
  ]
}

resource "aws_lambda_function" "query_metrics" {
  function_name    = "query-license-plate-metrics"
  filename         = data.archive_file.query_metrics_lambda.output_path
  runtime          = "python3.9"
  handler          = "app.lambda_handler"
  source_code_hash = data.archive_file.query_metrics_lambda.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  timeout          = 30

  environment {
    variables = {
      DB_HOST     = "postgres"
      DB_NAME     = "licenseplate_db"
      DB_USER     = "postgres"
      DB_PASSWORD = "postgres"
      DB_PORT     = "5432"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs
  ]
}

resource "aws_cloudwatch_log_group" "process_readings_logs" {
  name              = "/aws/lambda/process-license-plate-readings"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "query_metrics_logs" {
  name              = "/aws/lambda/query-license-plate-metrics"
  retention_in_days = 14
}

# Crear un bucket S3 para alojar la definición de API Gateway OpenAPI
resource "aws_s3_bucket" "openapi_bucket" {
  bucket = "openapi-definition-bucket"
  force_destroy = true
}

# Crear un documento OpenAPI para definir la API
resource "aws_s3_bucket_object" "openapi_definition" {
  bucket = aws_s3_bucket.openapi_bucket.bucket
  key    = "openapi.json"
  content = jsonencode({
    openapi = "3.0.1"
    info = {
      title   = "LicensePlateAPI"
      version = "1.0"
    }
    paths = {
      "/readings" = {
        post = {
          "x-amazon-apigateway-integration" = {
            uri          = aws_lambda_function.process_readings.invoke_arn
            type         = "aws_proxy"
            httpMethod   = "POST"
            payloadFormatVersion = "1.0"
          }
        }
      }
      "/metrics" = {
        get = {
          "x-amazon-apigateway-integration" = {
            uri          = aws_lambda_function.query_metrics.invoke_arn
            type         = "aws_proxy"
            httpMethod   = "POST"
            payloadFormatVersion = "1.0"
          }
        }
      }
    }
  })
  content_type = "application/json"
}

# Crear la API Gateway usando la definición OpenAPI
resource "aws_api_gateway_rest_api" "license_plate_api" {
  name        = "LicensePlateAPI"
  description = "License Plate Readings API"
  body        = aws_s3_bucket_object.openapi_definition.content

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Desplegar la API Gateway
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  
  triggers = {
    redeployment = sha256(aws_s3_bucket_object.openapi_definition.content)
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Crear una etapa "dev" para la API Gateway
resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  stage_name    = "dev"
}

# Configurar permisos Lambda para permitir invocaciones desde API Gateway
resource "aws_lambda_permission" "apigw_process_readings" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_readings.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.license_plate_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_query_metrics" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_metrics.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.license_plate_api.execution_arn}/*/*"
}

# Configurar un dominio personalizado para la API Gateway con una URL fija
resource "aws_api_gateway_domain_name" "fixed_api_domain" {
  domain_name = "api.localstack.cloud"
  regional_certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/12345678-1234-1234-1234-123456789012"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Mapear la etapa de la API al dominio personalizado
resource "aws_api_gateway_base_path_mapping" "api_mapping" {
  api_id      = aws_api_gateway_rest_api.license_plate_api.id
  stage_name  = aws_api_gateway_stage.dev.stage_name
  domain_name = aws_api_gateway_domain_name.fixed_api_domain.domain_name
}

# Script de ayuda para imprimir las URLs de los endpoints
resource "null_resource" "print_endpoints" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "===== API ENDPOINTS ====="
      echo "Reading endpoint: http://localhost:4566/dev/readings"
      echo "Metrics endpoint: http://localhost:4566/dev/metrics"
      echo "========================="
    EOT
  }
  
  depends_on = [
    aws_api_gateway_stage.dev
  ]
}

output "api_url" {
  description = "Base URL for API Gateway"
  value       = "http://localhost:4566/dev"
}

output "readings_endpoint" {
  description = "URL for the process_readings endpoint"
  value       = "http://localhost:4566/dev/readings"
}

output "metrics_endpoint" {
  description = "URL for the query_metrics endpoint"
  value       = "http://localhost:4566/dev/metrics"
}