# License Plate Processing System

A serverless application that processes license plate readings and determines applicable advertisements based on campaign rules.

## Overview

This system is designed to capture license plate readings from various checkpoints and serve targeted advertisements based on predefined campaign rules. It uses AWS serverless architecture with LocalStack for local development and testing.

### Key Features

- Process license plate readings in real-time
- Apply campaign rules based on location, time window, and exposure limits
- Store readings and ad exposures in PostgreSQL
- Query metrics about readings and ad campaigns
- Fully containerized development environment
- Comprehensive test suite
- Interactive Swagger UI for API testing and documentation ([View API Documentation](./swagger-ui.html))

## Architecture

The application consists of:

- Two AWS Lambda functions:
  - `process-license-plate-readings`: Processes incoming readings and determines applicable ads
  - `query-license-plate-metrics`: Provides metrics about readings and ad exposures
- API Gateway endpoints for the Lambda functions
- PostgreSQL database for storing readings and ad exposures
- Infrastructure as Code using Terraform
- Docker-based local development environment

## Prerequisites

- Docker and Docker Compose
- Curl or Postman (for testing APIs)

## Setup Instructions

### 1. Clone the Repository

```bash
git clone <repository-url>
cd <repository-directory>
```

### 2. Start the Environment

```bash
docker-compose up -d
```

This command will:
- Start LocalStack (AWS services emulator)
- Start PostgreSQL database and pgAdmin
- Initialize the database tables
- Build Lambda deployment packages
- Deploy Terraform infrastructure

### 3. Wait for Initialization

The system takes about 30-45 seconds to fully initialize. You can check if the setup is complete by monitoring the logs:

```bash
docker logs terraform
```

Wait until you see `Apply complete!` in the logs.

## Testing the APIs

You can test the APIs using either the Swagger UI or direct curl commands.

### Option 1: Using Swagger UI

1. Get your API ID by running the provided script:
   ```bash
   ./get-api-id.sh
   ```

2. Open the Swagger UI in your browser by clicking on [API Documentation](./swagger-ui.html)

3. Enter the API ID in the field at the top of the page and click "Update Swagger"

4. Use the interactive documentation to test the endpoints

### Option 2: Using curl commands

#### 1. Get the API ID

```bash
API_ID=$(docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis | grep "id" | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')
echo $API_ID
```

#### 2. Process License Plate Reading

```bash
curl -X POST \
  http://localhost:4566/restapis/$API_ID/dev/_user_request_/readings \
  -H 'Content-Type: application/json' \
  -d '{
    "reading_id": "READ123",
    "timestamp": "2023-06-10T14:30:00.000+00:00",
    "license_plate": "ABC123",
    "checkpoint_id": "CHECK_01",
    "location": {
        "latitude": 37.7749,
        "longitude": -122.4194
    }
}'
```

> **Note**: The timestamp must be in ISO 8601 format. Using `2023-06-10T14:30:00.000+00:00` format ensures compatibility with the parser.

Expected response:
```json
{
    "reading_id": "READ123",
    "processed": true,
    "ad_served": {
        "campaign_id": "CAMP_001",
        "ad_content": "AD_001"
    }
}
```

#### 3. Query Metrics

```bash
curl -X GET \
  "http://localhost:4566/restapis/$API_ID/dev/_user_request_/metrics?limit=5"
```

Expected response:
```json
{
    "readings_by_checkpoint": [
        {
            "checkpoint_id": "CHECK_01",
            "total_readings": 5
        },
        {
            "checkpoint_id": "CHECK_02",
            "total_readings": 3
        }
    ],
    "ads_by_campaign": [
        {
            "campaign_id": "CAMP_001",
            "total_ads_shown": 7
        }
    ],
    "recent_exposures": [
        {
            "exposure_id": 7,
            "campaign_id": "CAMP_001",
            "ad_content": "AD_001",
            "timestamp": "2023-06-10T14:30:00Z",
            "reading_id": "READ123",
            "license_plate": "ABC123",
            "checkpoint_id": "CHECK_01"
        }
    ],
    "metadata": {
        "limit_applied": 5
    }
}
```

## Running Tests

The project includes both unit tests and end-to-end tests:

### Unit Tests

To run unit tests for the Lambda functions:

```bash
# For process_readings Lambda
docker exec lambda-deps cd /lambda/process_readings && python -m unittest test.py

# For query_metrics Lambda
docker exec lambda-deps cd /lambda/query_metrics && python -m unittest test.py
```

### End-to-End Tests

To run the end-to-end test suite that validates the entire system:

```bash
./e2e-tests.sh
```

This will run a series of test cases that verify different aspects of the system's functionality.

## Database Access

You can use pgAdmin to inspect the database:

1. Open your browser and navigate to `http://localhost:5050`
2. Login with:
   - Email: admin@admin.com
   - Password: admin
3. Add a new server with:
   - Host: postgres
   - Port: 5432
   - Database: licenseplate_db
   - Username: postgres
   - Password: postgres

Alternatively, you can query the database directly with these commands:

```bash
# Check readings
docker exec -it postgres psql -U postgres -d licenseplate_db -c "SELECT * FROM license_plate_readings"

# Check exposures
docker exec -it postgres psql -U postgres -d licenseplate_db -c "SELECT * FROM ad_exposures"
```

## Campaign Rules

The system comes with two predefined campaigns:

1. **CAMP_001**:
   - Locations: CHECK_01, CHECK_02
   - Time window: 08:00 - 20:00
   - Max exposures per plate: 3
   - Ad content: AD_001

2. **CAMP_002**:
   - Locations: CHECK_03, CHECK_04
   - Time window: 10:00 - 22:00
   - Max exposures per plate: 5
   - Ad content: AD_002

## Technical Details

### Database Schema

**License Plate Readings Table**
- `id`: Serial primary key
- `reading_id`: Unique identifier for the reading
- `timestamp`: When the reading occurred
- `license_plate`: The license plate number
- `checkpoint_id`: ID of the checkpoint where the reading occurred
- `latitude`: Geographic latitude
- `longitude`: Geographic longitude
- `created_at`: When the record was created

**Ad Exposures Table**
- `id`: Serial primary key
- `reading_id`: Reference to the license plate reading
- `campaign_id`: ID of the campaign
- `ad_content`: Content identifier for the ad
- `exposure_timestamp`: When the ad was shown
- `created_at`: When the record was created

### Implementation Details

1. **Processing Lambda Logic**:
   - License plate readings are validated and stored
   - Campaign rules (location, time window, exposure limits) are applied
   - If applicable, an ad exposure is recorded
   - Returns processing result with ad information if served

2. **Metrics Lambda Logic**:
   - Counts readings by checkpoint
   - Calculates total ads shown by campaign
   - Retrieves recent exposures with details
   - Supports query parameters for customization

3. **Error Handling**:
   - Input validation with detailed error messages
   - Database connection management
   - Proper HTTP status codes for different error scenarios
   - Comprehensive logging

## Troubleshooting

### API Connection Issues

If you can't connect to the API endpoints, verify that LocalStack and Terraform have finished initializing:

```bash
# Check if API Gateway is properly deployed
docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis

# Check Lambda functions
docker exec localstack aws --endpoint-url=http://localhost:4566 lambda list-functions
```

### Database Connection Issues

If Lambda functions can't connect to the database, verify connectivity:

```bash
docker exec localstack ping -c 3 postgres
```

### Lambda Execution Issues

Check the CloudWatch logs for any Lambda errors:

```bash
docker exec localstack aws --endpoint-url=http://localhost:4566 logs describe-log-groups

# Get the latest log stream for a function
LOG_GROUP="/aws/lambda/process-license-plate-readings"
LOG_STREAM=$(docker exec localstack aws --endpoint-url=http://localhost:4566 logs describe-log-streams --log-group-name "$LOG_GROUP" --order-by LastEventTime --descending --limit 1 | grep logStreamName | cut -d'"' -f4)

# View the logs
docker exec localstack aws --endpoint-url=http://localhost:4566 logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM"
```

## Clean Up

To stop and remove all containers:

```bash
docker-compose down -v
```

This will also remove the volumes, including the PostgreSQL data.

## Swagger API Documentation

The project includes a comprehensive Swagger (OpenAPI) documentation to help you interact with the API:

- **Swagger UI**: A browser-based UI for testing the API and reading documentation
- **OpenAPI Specification**: A formal description of the API endpoints, parameters, and schemas
- **Helper Script**: A utility to easily retrieve your API ID from LocalStack

### Swagger Features

- Complete API documentation with detailed schemas
- Interactive "Try it out" functionality to test endpoints
- Request and response examples
- Easy parameter input with validation
- Error response documentation

### Setting Up Swagger

1. Start the environment with `docker-compose up -d`
2. Run the API ID helper script: `./get-api-id.sh`
3. Open the Swagger UI in your browser: [API Documentation](./swagger-ui.html)
4. Enter your API ID and click "Update Swagger"

## Future Improvements

- Move campaign rules to the database
- Add authentication/authorization
- Implement more sophisticated campaign rules based on vehicle type, time of day, etc.
- Create a UI for monitoring and management
- Add additional metrics and reporting features
- Implement automated CI/CD pipeline
- Add performance optimization for high-traffic scenarios
- Implement a notification system for campaign managers
- Expand Swagger documentation with more examples and use cases