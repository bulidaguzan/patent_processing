# AWS Provider configuration for LocalStack
# Using mock credentials and disabling validations since we're using a local emulator
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # Configure endpoints to use LocalStack services
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

# IAM role for Lambda execution
# This role allows the Lambda service to assume the role and execute the functions
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

# IAM policy for Lambda logging to CloudWatch
# This policy grants permissions to write logs to CloudWatch
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

# Attach the logging policy to the Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}

# Lambda function for processing license plate readings
# This function handles incoming readings and determines applicable advertisements
resource "aws_lambda_function" "process_readings" {
  function_name = "process-license-plate-readings"
  filename      = "/packages/process_readings.zip"
  runtime       = "python3.9"
  handler       = "app.lambda_handler"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

  # Environment variables for database connection
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

# Lambda function for querying metrics
# This function provides metrics about readings and ad exposures
resource "aws_lambda_function" "query_metrics" {
  function_name = "query-license-plate-metrics"
  filename      = "/packages/query_metrics.zip"
  runtime       = "python3.9"
  handler       = "app.lambda_handler"
  role          = aws_iam_role.lambda_role.arn
  timeout       = 30

  # Environment variables for database connection
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

# CloudWatch log group for process_readings Lambda
resource "aws_cloudwatch_log_group" "process_readings_logs" {
  name              = "/aws/lambda/process-license-plate-readings"
  retention_in_days = 14
}

# CloudWatch log group for query_metrics Lambda
resource "aws_cloudwatch_log_group" "query_metrics_logs" {
  name              = "/aws/lambda/query-license-plate-metrics"
  retention_in_days = 14
}

# API Gateway REST API definition
resource "aws_api_gateway_rest_api" "license_plate_api" {
  name        = "LicensePlateAPI"
  description = "License Plate Readings API"
}

# Resource for the /readings endpoint in API Gateway
resource "aws_api_gateway_resource" "readings_resource" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "readings"
}

# Resource for the /metrics endpoint in API Gateway
resource "aws_api_gateway_resource" "metrics_resource" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "metrics"
}

# HTTP POST method for the /readings endpoint
# This handles incoming license plate readings
resource "aws_api_gateway_method" "readings_post" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.readings_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration between API Gateway and the process_readings Lambda
# This connects the POST /readings endpoint to the Lambda function
resource "aws_api_gateway_integration" "readings_post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.readings_resource.id
  http_method             = aws_api_gateway_method.readings_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.process_readings.invoke_arn
}

# HTTP GET method for the /metrics endpoint
# This allows querying metrics about readings and exposures
resource "aws_api_gateway_method" "metrics_get" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.metrics_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration between API Gateway and the query_metrics Lambda
# This connects the GET /metrics endpoint to the Lambda function
resource "aws_api_gateway_integration" "metrics_get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.metrics_resource.id
  http_method             = aws_api_gateway_method.metrics_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query_metrics.invoke_arn
}

# API Gateway deployment
# This creates a deployment of the API in the "dev" stage
resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.readings_post_integration,
    aws_api_gateway_integration.metrics_get_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  stage_name  = "dev"
}

# Lambda permission for API Gateway to invoke the process_readings Lambda
resource "aws_lambda_permission" "apigw_process_readings" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_readings.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.license_plate_api.execution_arn}/*/*"
}

# Lambda permission for API Gateway to invoke the query_metrics Lambda
resource "aws_lambda_permission" "apigw_query_metrics" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_metrics.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.license_plate_api.execution_arn}/*/*"
}

# Output the base API Gateway URL
output "api_gateway_url" {
  value = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_"
}

# Output the API base URL
output "api_url" {
  description = "Base URL for API Gateway"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_"
}

# Output the readings endpoint URL
output "readings_endpoint" {
  description = "URL for the process_readings endpoint"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/readings"
}

# Output the metrics endpoint URL
output "metrics_endpoint" {
  description = "URL for the query_metrics endpoint"
  value       = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.license_plate_api.id}/dev/_user_request_/metrics"
}

# Execute a local command to print endpoint information to the console
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