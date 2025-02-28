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

resource "aws_api_gateway_rest_api" "license_plate_api" {
  name        = "LicensePlateAPI"
  description = "License Plate Readings API"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "readings" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "readings"
}

resource "aws_api_gateway_method" "post_reading" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.readings.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_reading_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.readings.id
  http_method             = aws_api_gateway_method.post_reading.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.process_readings.invoke_arn
}

resource "aws_api_gateway_resource" "metrics" {
  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
  parent_id   = aws_api_gateway_rest_api.license_plate_api.root_resource_id
  path_part   = "metrics"
}

resource "aws_api_gateway_method" "get_metrics" {
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  resource_id   = aws_api_gateway_resource.metrics.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_metrics_integration" {
  rest_api_id             = aws_api_gateway_rest_api.license_plate_api.id
  resource_id             = aws_api_gateway_resource.metrics.id
  http_method             = aws_api_gateway_method.get_metrics.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query_metrics.invoke_arn
}

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

resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.post_reading_integration,
    aws_api_gateway_integration.get_metrics_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.license_plate_api.id
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.license_plate_api.id
  stage_name    = "dev"
}

output "api_url" {
  description = "Base URL for API Gateway"
  value       = "${aws_api_gateway_deployment.api_deployment.invoke_url}"
}

output "readings_endpoint" {
  description = "URL for the process_readings endpoint"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/readings"
}

output "metrics_endpoint" {
  description = "URL for the query_metrics endpoint"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/metrics"
}