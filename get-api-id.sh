#!/bin/bash

# Colors for better visualization
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Fetching API ID from LocalStack...${NC}"

# Check if LocalStack is running
if ! docker ps | grep -q localstack; then
  echo -e "${RED}Error: LocalStack container is not running.${NC}"
  echo -e "Please start your environment with: ${GREEN}docker-compose up -d${NC}"
  exit 1
fi

# Get API ID from LocalStack
API_ID=$(docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis | grep "id" | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')

if [ -z "$API_ID" ]; then
  echo -e "${RED}Error: Could not retrieve API ID.${NC}"
  echo -e "Possible reasons:"
  echo -e "  - Terraform has not completed deployment"
  echo -e "  - API Gateway was not created correctly"
  echo -e "  - AWS CLI command failed"
  echo -e "\nTry running: ${GREEN}docker logs terraform${NC} to check Terraform status."
  exit 1
fi

echo -e "${GREEN}API ID successfully retrieved: ${YELLOW}$API_ID${NC}"
echo ""
echo -e "You can now use this API ID in the following ways:"
echo ""
echo -e "1. ${YELLOW}Swagger UI:${NC} Enter the API ID in the field at the top and click 'Update Swagger'"
echo ""
echo -e "2. ${YELLOW}Direct API calls:${NC}"
echo -e "   Export it as an environment variable:"
echo -e "   ${GREEN}export API_ID=$API_ID${NC}"
echo ""
echo -e "   Process a reading:"
echo -e "   ${GREEN}curl -X POST \\
  http://localhost:4566/restapis/\$API_ID/dev/_user_request_/readings \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"reading_id\": \"READ123\",
    \"timestamp\": \"2023-06-10T14:30:00Z\",
    \"license_plate\": \"ABC123\",
    \"checkpoint_id\": \"CHECK_01\",
    \"location\": {
        \"latitude\": 37.7749,
        \"longitude\": -122.4194
    }
}'${NC}"
echo ""
echo -e "   Query metrics:"
echo -e "   ${GREEN}curl -X GET \"http://localhost:4566/restapis/\$API_ID/dev/_user_request_/metrics?limit=5\"${NC}"
echo ""
echo -e "${YELLOW}API ID has been saved to:${NC}"
echo -e "  ${GREEN}$API_ID${NC}"