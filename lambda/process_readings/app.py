import json
import os
import psycopg2
import logging
import datetime
from typing import Dict, Any, List, Optional, Tuple

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


class DatabaseError(Exception):
    """Exception for database-related errors"""

    pass


class ValidationError(Exception):
    """Exception for data validation errors"""

    pass


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
    except psycopg2.OperationalError as e:
        logger.error(f"Database connection error: {e}")
        raise DatabaseError(f"Failed to connect to database: {e}")
    except Exception as e:
        logger.error(f"Unexpected database error: {e}")
        raise DatabaseError(f"Unexpected database error: {e}")


def validate_reading(reading: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    """
    Validate the format of the license plate reading

    Returns:
        Tuple of (is_valid, error_message)
    """
    required_fields = [
        "reading_id",
        "timestamp",
        "license_plate",
        "checkpoint_id",
        "location",
    ]

    # Check if all required fields are present
    for field in required_fields:
        if field not in reading:
            return False, f"Missing required field: {field}"

    # Validate reading_id
    if not isinstance(reading["reading_id"], str) or len(reading["reading_id"]) == 0:
        return False, "Invalid reading_id: must be a non-empty string"

    # Validate license_plate
    if (
        not isinstance(reading["license_plate"], str)
        or len(reading["license_plate"]) == 0
    ):
        return False, "Invalid license_plate: must be a non-empty string"

    # Validate checkpoint_id
    if (
        not isinstance(reading["checkpoint_id"], str)
        or len(reading["checkpoint_id"]) == 0
    ):
        return False, "Invalid checkpoint_id: must be a non-empty string"

    # Validate location
    if not isinstance(reading["location"], dict):
        return False, "Invalid location: must be an object"

    if "latitude" not in reading["location"] or "longitude" not in reading["location"]:
        return False, "Invalid location: must contain latitude and longitude"

    try:
        lat = float(reading["location"]["latitude"])
        lng = float(reading["location"]["longitude"])

        # Basic geographic validation for latitude (-90 to 90)
        if lat < -90 or lat > 90:
            return False, "Invalid latitude: must be between -90 and 90"

        # Basic geographic validation for longitude (-180 to 180)
        if lng < -180 or lng > 180:
            return False, "Invalid longitude: must be between -180 and 180"
    except (ValueError, TypeError):
        return (
            False,
            "Invalid location coordinates: latitude and longitude must be numbers",
        )

    # Validate timestamp format
    try:
        datetime.datetime.fromisoformat(reading["timestamp"].replace("Z", "+00:00"))
        return True, None
    except (ValueError, TypeError, AttributeError):
        return (
            False,
            "Invalid timestamp: must be in ISO 8601 format (YYYY-MM-DDTHH:MM:SSZ)",
        )


def save_reading(conn, reading: Dict[str, Any]) -> None:
    """Save license plate reading to database"""
    query = """
    INSERT INTO license_plate_readings 
    (reading_id, timestamp, license_plate, checkpoint_id, latitude, longitude)
    VALUES (%s, %s, %s, %s, %s, %s)
    """

    try:
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
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise ValidationError(f"Duplicate reading_id: {reading['reading_id']}")
    except psycopg2.errors.InFailedSqlTransaction:
        conn.rollback()
        raise DatabaseError("Transaction failed, connection rolled back")
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"Database error when saving reading: {e}")
        raise DatabaseError(f"Failed to save reading: {e}")


def get_exposure_count(conn, license_plate: str, campaign_id: str) -> int:
    """Get the number of times a license plate has been exposed to a campaign"""
    query = """
    SELECT COUNT(*) FROM ad_exposures ae
    JOIN license_plate_readings lpr ON ae.reading_id = lpr.reading_id
    WHERE lpr.license_plate = %s AND ae.campaign_id = %s
    """

    try:
        with conn.cursor() as cur:
            cur.execute(query, (license_plate, campaign_id))
            count = cur.fetchone()[0]
            return count
    except (psycopg2.Error, Exception) as e:
        logger.error(f"Error getting exposure count: {e}")
        raise DatabaseError(f"Failed to get exposure count: {e}")


def save_exposure(
    conn, reading_id: str, campaign_id: str, ad_content: str, timestamp: str
) -> None:
    """Save ad exposure to database"""
    query = """
    INSERT INTO ad_exposures
    (reading_id, campaign_id, ad_content, exposure_timestamp)
    VALUES (%s, %s, %s, %s)
    """

    try:
        with conn.cursor() as cur:
            cur.execute(query, (reading_id, campaign_id, ad_content, timestamp))
            conn.commit()
    except psycopg2.errors.ForeignKeyViolation:
        conn.rollback()
        raise ValidationError(
            f"Invalid reading_id: {reading_id} - doesn't exist in readings table"
        )
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"Database error when saving exposure: {e}")
        raise DatabaseError(f"Failed to save exposure: {e}")


def is_in_time_window(
    reading_time: datetime.datetime, start_time_str: str, end_time_str: str
) -> bool:
    """Check if reading time is within campaign time window"""
    try:
        start_hour, start_minute = map(int, start_time_str.split(":"))
        end_hour, end_minute = map(int, end_time_str.split(":"))

        reading_hour = reading_time.hour
        reading_minute = reading_time.minute

        start_minutes = start_hour * 60 + start_minute
        end_minutes = end_hour * 60 + end_minute
        reading_minutes = reading_hour * 60 + reading_minute

        return start_minutes <= reading_minutes <= end_minutes
    except (ValueError, AttributeError) as e:
        logger.error(f"Error in time window calculation: {e}")
        # Return False on error as a safe default
        return False


def determine_applicable_campaign(
    conn, reading: Dict[str, Any]
) -> Optional[Dict[str, Any]]:
    """Determine which campaign is applicable for the license plate reading"""
    try:
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
    except Exception as e:
        logger.error(f"Error determining applicable campaign: {e}")
        # Return None on error as a safe default
        return None


def api_response(status_code: int, body: Dict[str, Any]) -> Dict[str, Any]:
    """Helper function to format API Gateway response"""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",  # CORS support
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "POST,OPTIONS",
        },
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    """AWS Lambda Handler"""
    conn = None  # Initialize connection to None

    try:
        logger.info(f"Received event: {json.dumps(event)}")

        # Parse request body from API Gateway event
        body = event.get("body")
        if body is None:
            return api_response(400, {"error": "Missing request body"})

        if isinstance(body, str):
            try:
                body = json.loads(body)
            except json.JSONDecodeError:
                return api_response(400, {"error": "Invalid JSON in request body"})

        # Validate reading
        is_valid, error_message = validate_reading(body)
        if not is_valid:
            return api_response(400, {"error": error_message})

        # Connect to database
        conn = get_db_connection()

        # Process the reading in a try-except block
        try:
            # Save reading
            save_reading(conn, body)

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

            return api_response(200, result)

        except ValidationError as e:
            return api_response(409, {"error": str(e)})

        except DatabaseError as e:
            return api_response(500, {"error": f"Database error: {str(e)}"})

    except ValidationError as e:
        return api_response(400, {"error": str(e)})

    except DatabaseError as e:
        return api_response(500, {"error": f"Database error: {str(e)}"})

    except Exception as e:
        logger.error(f"Unhandled error: {str(e)}", exc_info=True)
        return api_response(500, {"error": f"Internal server error: {str(e)}"})

    finally:
        # Ensure database connection is closed even if an exception occurs
        if conn is not None:
            try:
                conn.close()
                logger.info("Database connection closed")
            except Exception as e:
                logger.error(f"Error closing database connection: {str(e)}")
