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
docker-compose logs -f terraform
```

Wait until you see `Apply complete!` in the logs.

## Testing the APIs

### Process License Plate Reading

```bash
curl -X POST \
  http://localhost:4566/restapis/<api-id>/dev/_user_request_/readings \
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

### Query Metrics

```bash
curl -X GET \
  "http://localhost:4566/restapis/<api-id>/dev/_user_request_/metrics?limit=5"
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

## Getting API IDs

After deployment, you can find the API ID by running:

```bash
docker exec terraform aws --endpoint-url=http://localstack:4566 apigateway get-rest-apis
```

Use the `id` field from the output in your API requests.

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

## Database Schema

### License Plate Readings Table

Stores all incoming license plate readings.

- `id`: Serial primary key
- `reading_id`: Unique identifier for the reading
- `timestamp`: When the reading occurred
- `license_plate`: The license plate number
- `checkpoint_id`: ID of the checkpoint where the reading occurred
- `latitude`: Geographic latitude
- `longitude`: Geographic longitude
- `created_at`: When the record was created

### Ad Exposures Table

Tracks which ads were shown for which readings.

- `id`: Serial primary key
- `reading_id`: Reference to the license plate reading
- `campaign_id`: ID of the campaign
- `ad_content`: Content identifier for the ad
- `exposure_timestamp`: When the ad was shown
- `created_at`: When the record was created

## Implementation Details

### Processing Logic

1. When a reading is received, it's validated and stored
2. The system determines which campaign applies based on:
   - Whether the checkpoint is included in the campaign's locations
   - Whether the current time is within the campaign's time window
   - Whether the license plate has been exposed to the campaign less than the maximum allowed times
3. If a campaign applies, an ad exposure is recorded

### Metrics Calculation

The metrics endpoint provides:
- Total readings per checkpoint
- Total ads shown per campaign
- List of recent ad exposures with details

## Design Considerations

- **Simplicity**: The system uses a straightforward schema and processing logic
- **Extensibility**: Additional campaign rules could be easily added
- **Local Development**: Full AWS emulation using LocalStack for easy testing
- **Infrastructure as Code**: Terraform ensures repeatable deployments

## Limitations and Future Improvements

- Campaign rules are currently hardcoded; they could be moved to a database table
- There's no authentication or authorization
- Error handling could be enhanced for production use
- Performance optimizations could be added for high-volume scenarios
- Additional campaign rule types could be implemented (day of week, weather, etc.)

## Troubleshooting

### API Gateway Issues

If you're having trouble with the API endpoints, try:

```bash
docker exec terraform aws --endpoint-url=http://localstack:4566 apigateway get-stages --rest-api-id <api-id>
```

### Database Issues

To connect directly to the database for troubleshooting:

```bash
docker exec -it postgres psql -U postgres -d licenseplate_db
```

Common SQL queries for debugging:
```sql
-- Check readings
SELECT * FROM license_plate_readings ORDER BY timestamp DESC LIMIT 5;

-- Check exposures
SELECT * FROM ad_exposures ORDER BY exposure_timestamp DESC LIMIT 5;
```

### Lambda Issues

To check Lambda logs:

```bash
docker exec terraform aws --endpoint-url=http://localstack:4566 logs describe-log-streams --log-group-name "/aws/lambda/process-license-plate-readings"
```

## Clean Up

To stop and remove all containers:

```bash
docker-compose down -v
```

This will also remove the volumes, including the PostgreSQL data.





