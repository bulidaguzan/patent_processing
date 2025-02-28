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
    route53        = "http://localstack:4566"
  }
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
  function_name = "process-license-plate-readings"
  filename      = "/packages/process_readings.zip"
  runtime       = "python3.9"
  handler       = "app.lambda_handler"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

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
  function_name = "query-license-plate-metrics"
  filename      = "/packages/query_metrics.zip"
  runtime       = "python3.9"
  handler       = "app.lambda_handler"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

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

# API Gateway - Simplified approach without custom domain
resource "aws_api_gateway_rest_api" "license_plate_api" {
  name        = "LicensePlateAPI"
  description = "License Plate Readings API"
}

# Create a resource for /readings endpoint
resource "aws_api_gateway_resource" "readings_resource" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "readings"
}

# Create a resource for /metrics endpoint
resource "aws_api_gateway_resource" "metrics_resource" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "metrics"
}

# POST method for /readings
resource "aws_api_gateway_method" "readings_post" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.readings_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration for POST /readings
resource "aws_api_gateway_integration" "readings_post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.readings_resource.id
  http_method             = aws_api_gateway_method.readings_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.process_readings.invoke_arn
}

# GET method for /metrics
resource "aws_api_gateway_method" "metrics_get" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.metrics_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration for GET /metrics
resource "aws_api_gateway_integration" "metrics_get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.metrics_resource.id
  http_method             = aws_api_gateway_method.metrics_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query_metrics.invoke_arn
}

# Deploy the API
resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.readings_post_integration,
    aws_api_gateway_integration.metrics_get_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  stage_name  = "dev"
}

# Permissions for Lambda functions
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

output "api_url" {
  description = "Base URL for API Gateway"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_"
}

output "readings_endpoint" {
  description = "URL for the process_readings endpoint"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/readings"
}

output "metrics_endpoint" {
  description = "URL for the query_metrics endpoint"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/metrics"
}

resource "null_resource" "print_endpoints" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "===== API ENDPOINTS ====="
      echo "API Gateway ID: ${aws_api_gateway_rest_api.license_plate_api.id}"
      echo "Reading endpoint: http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/readings"
      echo "Metrics endpoint: http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/metrics"
      echo "========================="
    EOT
  }
  
  depends_on = [
    aws_api_gateway_deployment.api_deployment
  ]
}