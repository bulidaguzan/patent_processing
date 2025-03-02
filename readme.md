# License Plate Processing System

A serverless application that processes license plate readings and determines applicable advertisements based on campaign rules.

## Overview

This system is designed to capture license plate readings from various checkpoints and serve targeted advertisements based on predefined campaign rules. It uses AWS serverless architecture with LocalStack for local development and testing.

### Key Features

- Process license plate readings in real-time
- Apply campaign rules based on location, time, and exposure limits
- Store readings and ad exposures in PostgreSQL
- Query metrics about readings and ad campaigns
- Fully containerized development environment

## Architecture

The application consists of:

- Two AWS Lambda functions:
  - `process-license-plate-readings`: Processes incoming readings and determines applicable ads
  - `query-license-plate-metrics`: Provides metrics about readings and ad exposures
- API Gateway endpoints for the Lambda functions
- PostgreSQL database for storing readings and ad exposures
- Infrastructure as Code using Terraform

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
- Start PostgreSQL database
- Initialize the database tables
- Deploy Terraform infrastructure

### 3. Wait for Initialization

The system takes about 30-45 seconds to fully initialize. You can check if the setup is complete by monitoring the logs:

```bash
docker logs terraform
```

Wait until you see `Apply complete!` in the logs.

## Testing the APIs

### 1. Get the API ID

```bash
API_ID=$(docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis | grep "id" | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')
echo $API_ID
```

### 2. Process License Plate Reading

```bash
curl -X POST \
  http://localhost:4566/restapis/$API_ID/dev/_user_request_/readings \
  -H 'Content-Type: application/json' \
  -d '{
    "reading_id": "READ123",
    "timestamp": "2023-06-10T14:30:00Z",
    "license_plate": "ABC123",
    "checkpoint_id": "CHECK_01",
    "location": {
        "latitude": 37.7749,
        "longitude": -122.4194
    }
}'
```

Response:
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

### 3. Query Metrics

```bash
curl -X GET \
  "http://localhost:4566/restapis/$API_ID/dev/_user_request_/metrics?limit=5"
```

Response:
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
    ]
}
```

## Database Queries

You can verify the data in the database with these commands:

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

1. **Processing Logic**:
   - License plate readings are validated and stored
   - Campaign rules (location, time window, exposure limits) are applied
   - If applicable, an ad exposure is recorded

2. **Metrics Logic**:
   - Counts readings by checkpoint
   - Calculates total ads shown by campaign
   - Retrieves recent exposures with details

## Common Issues & Troubleshooting

### AWS Credentials for LocalStack

LocalStack requires AWS credentials even though it's a local emulation. Set them with:

```bash
docker exec localstack aws configure set aws_access_key_id test
docker exec localstack aws configure set aws_secret_access_key test
docker exec localstack aws configure set region us-east-1
```

For convenience, these credentials are already configured in the docker-compose.yml file.

### Connection Issues Between Containers

If Lambda functions can't connect to the database, verify connectivity:

```bash
docker exec localstack ping -c 3 postgres
```

### Lambda Packaging Issues

If you encounter module import errors with `psycopg2`, make sure the Lambda deployment packages are created correctly with all native dependencies:

```bash
# Use the proper pip install command for Lambda
pip install --platform manylinux2014_x86_64 --implementation cp --python 3.9 --only-binary=:all: --upgrade -r requirements.txt -t .
```

### Terraform Not Running

If Terraform container exits prematurely:

```bash
# Manually run Terraform
docker exec -it terraform terraform apply -auto-approve
```

## Clean Up

To stop and remove all containers:

```bash
docker-compose down -v
```

This will also remove the volumes, including the PostgreSQL data.

## Future Improvements

- Move campaign rules to the database
- Add authentication/authorization
- Implement more sophisticated campaign rules
- Create a UI for monitoring and management
- Add additional metrics and reporting features
- Implement automated testing