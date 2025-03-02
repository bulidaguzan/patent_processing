import json
import os
import psycopg2
import logging
import datetime
from typing import Dict, Any, List, Optional

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Database connection parameters
DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_NAME = os.environ.get("DB_NAME", "licenseplate_db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres")
DB_PORT = os.environ.get("DB_PORT", "5432")

# Hard-coded campaign data (in a real scenario this would come from a DB)
CAMPAIGNS = [
    {
        "campaign_id": "CAMP_001",
        "locations": ["CHECK_01", "CHECK_02"],
        "time_window": {"start": "08:00", "end": "20:00"},
        "max_exposures_per_plate": 3,
        "ad_content": "AD_001",
    },
    {
        "campaign_id": "CAMP_002",
        "locations": ["CHECK_03", "CHECK_04"],
        "time_window": {"start": "10:00", "end": "22:00"},
        "max_exposures_per_plate": 5,
        "ad_content": "AD_002",
    },
]


def get_db_connection():
    """Establish a database connection"""
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            port=DB_PORT,
        )
        return conn
    except Exception as e:
        logger.error(f"Database connection error: {e}")
        raise


def validate_reading(reading: Dict[str, Any]) -> bool:
    """Validate the format of the license plate reading"""
    required_fields = [
        "reading_id",
        "timestamp",
        "license_plate",
        "checkpoint_id",
        "location",
    ]
    if not all(field in reading for field in required_fields):
        return False

    if (
        not isinstance(reading["location"], dict)
        or "latitude" not in reading["location"]
        or "longitude" not in reading["location"]
    ):
        return False

    try:
        # Validate timestamp format
        datetime.datetime.fromisoformat(reading["timestamp"].replace("Z", "+00:00"))
        return True
    except (ValueError, TypeError):
        return False


def save_reading(conn, reading: Dict[str, Any]) -> None:
    """Save license plate reading to database"""
    query = """
    INSERT INTO license_plate_readings 
    (reading_id, timestamp, license_plate, checkpoint_id, latitude, longitude)
    VALUES (%s, %s, %s, %s, %s, %s)
    """

    with conn.cursor() as cur:
        cur.execute(
            query,
            (
                reading["reading_id"],
                reading["timestamp"],
                reading["license_plate"],
                reading["checkpoint_id"],
                reading["location"]["latitude"],
                reading["location"]["longitude"],
            ),
        )
        conn.commit()


def get_exposure_count(conn, license_plate: str, campaign_id: str) -> int:
    """Get the number of times a license plate has been exposed to a campaign"""
    query = """
    SELECT COUNT(*) FROM ad_exposures ae
    JOIN license_plate_readings lpr ON ae.reading_id = lpr.reading_id
    WHERE lpr.license_plate = %s AND ae.campaign_id = %s
    """

    with conn.cursor() as cur:
        cur.execute(query, (license_plate, campaign_id))
        count = cur.fetchone()[0]
        return count


def save_exposure(
    conn, reading_id: str, campaign_id: str, ad_content: str, timestamp: str
) -> None:
    """Save ad exposure to database"""
    query = """
    INSERT INTO ad_exposures
    (reading_id, campaign_id, ad_content, exposure_timestamp)
    VALUES (%s, %s, %s, %s)
    """

    with conn.cursor() as cur:
        cur.execute(query, (reading_id, campaign_id, ad_content, timestamp))
        conn.commit()


def is_in_time_window(
    reading_time: datetime.datetime, start_time_str: str, end_time_str: str
) -> bool:
    """Check if reading time is within campaign time window"""
    start_hour, start_minute = map(int, start_time_str.split(":"))
    end_hour, end_minute = map(int, end_time_str.split(":"))

    reading_hour = reading_time.hour
    reading_minute = reading_time.minute

    start_minutes = start_hour * 60 + start_minute
    end_minutes = end_hour * 60 + end_minute
    reading_minutes = reading_hour * 60 + reading_minute

    return start_minutes <= reading_minutes <= end_minutes


def determine_applicable_campaign(
    conn, reading: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    """Determine which campaign is applicable for the license plate reading"""
    reading_time = datetime.datetime.fromisoformat(
        reading["timestamp"].replace("Z", "+00:00")
    )
    checkpoint_id = reading["checkpoint_id"]
    license_plate = reading["license_plate"]

    for campaign in CAMPAIGNS:
        # Check if checkpoint is in campaign locations
        if checkpoint_id in campaign["locations"]:
            # Check if time is within campaign window
            if is_in_time_window(
                reading_time,
                campaign["time_window"]["start"],
                campaign["time_window"]["end"],
            ):
                # Check exposure limit
                exposure_count = get_exposure_count(
                    conn, license_plate, campaign["campaign_id"]
                )
                if exposure_count < campaign["max_exposures_per_plate"]:
                    return campaign

    return None


def lambda_handler(event, context):
    """AWS Lambda Handler"""
    try:
        logger.info(f"Received event: {event}")

        # Parse request body from API Gateway event
        body = event.get("body")
        if body is None:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"error": "Missing request body"}),
            }

        if isinstance(body, str):
            body = json.loads(body)

        # Validate reading
        if not validate_reading(body):
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"error": "Invalid reading format"}),
            }

        # Connect to database
        conn = get_db_connection()

        # Save reading
        try:
            save_reading(conn, body)
        except psycopg2.errors.UniqueViolation:
            conn.rollback()
            return {
                "statusCode": 409,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"error": "Duplicate reading_id"}),
            }

        # Determine applicable campaign
        campaign = determine_applicable_campaign(conn, body)

        # Result object
        result = {"reading_id": body["reading_id"], "processed": True}

        # If campaign is applicable, save exposure and add to result
        if campaign:
            save_exposure(
                conn,
                body["reading_id"],
                campaign["campaign_id"],
                campaign["ad_content"],
                body["timestamp"],
            )
            result["ad_served"] = {
                "campaign_id": campaign["campaign_id"],
                "ad_content": campaign["ad_content"],
            }
        else:
            result["ad_served"] = None

        conn.close()

        # Return result
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(result),
        }

    except Exception as e:
        logger.error(f"Error processing reading: {str(e)}")
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"Internal server error: {str(e)}"}),
        }
