import json
import os
import psycopg2
import logging
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

# Maximum limit for querying exposures to prevent overloading
MAX_ALLOWED_LIMIT = 100


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


def validate_query_parameters(
    params: Dict[str, Any]
) -> Tuple[Dict[str, Any], Optional[str]]:
    """
    Validate query parameters

    Returns:
        Tuple of (validated_params, error_message)
    """
    validated_params = {}

    # Validate and process 'limit' parameter
    try:
        if "limit" in params and params["limit"] is not None:
            limit = int(params["limit"])

            # Ensure limit is positive
            if limit <= 0:
                return {}, "Parameter 'limit' must be a positive integer"

            # Enforce maximum limit to prevent overloading
            if limit > MAX_ALLOWED_LIMIT:
                limit = MAX_ALLOWED_LIMIT
        else:
            limit = 10  # Default value

        validated_params["limit"] = limit
    except (ValueError, TypeError):
        return {}, "Parameter 'limit' must be a valid integer"

    # Add additional parameter validations here as needed

    return validated_params, None


def get_readings_by_checkpoint(conn) -> List[Dict[str, Any]]:
    """Get total readings count by checkpoint"""
    query = """
    SELECT checkpoint_id, COUNT(*) as total_readings
    FROM license_plate_readings
    GROUP BY checkpoint_id
    ORDER BY checkpoint_id
    """

    try:
        with conn.cursor() as cur:
            cur.execute(query)
            results = cur.fetchall()

            return [
                {"checkpoint_id": row[0], "total_readings": row[1]} for row in results
            ]
    except psycopg2.Error as e:
        logger.error(f"Database error when retrieving readings by checkpoint: {e}")
        raise DatabaseError(f"Failed to get readings by checkpoint: {e}")


def get_ads_by_campaign(conn) -> List[Dict[str, Any]]:
    """Get total ads shown by campaign"""
    query = """
    SELECT campaign_id, COUNT(*) as total_ads_shown
    FROM ad_exposures
    GROUP BY campaign_id
    ORDER BY campaign_id
    """

    try:
        with conn.cursor() as cur:
            cur.execute(query)
            results = cur.fetchall()

            return [
                {"campaign_id": row[0], "total_ads_shown": row[1]} for row in results
            ]
    except psycopg2.Error as e:
        logger.error(f"Database error when retrieving ads by campaign: {e}")
        raise DatabaseError(f"Failed to get ads by campaign: {e}")


def get_recent_exposures(conn, limit: int = 10) -> List[Dict[str, Any]]:
    """Get recent ad exposures with reading details"""
    query = """
    SELECT 
        ae.id,
        ae.campaign_id,
        ae.ad_content,
        ae.exposure_timestamp,
        lpr.reading_id,
        lpr.license_plate,
        lpr.checkpoint_id
    FROM ad_exposures ae
    JOIN license_plate_readings lpr ON ae.reading_id = lpr.reading_id
    ORDER BY ae.exposure_timestamp DESC
    LIMIT %s
    """

    try:
        with conn.cursor() as cur:
            cur.execute(query, (limit,))
            results = cur.fetchall()

            return [
                {
                    "exposure_id": row[0],
                    "campaign_id": row[1],
                    "ad_content": row[2],
                    "timestamp": row[3].isoformat() if row[3] else None,
                    "reading_id": row[4],
                    "license_plate": row[5],
                    "checkpoint_id": row[6],
                }
                for row in results
            ]
    except psycopg2.Error as e:
        logger.error(f"Database error when retrieving recent exposures: {e}")
        raise DatabaseError(f"Failed to get recent exposures: {e}")


def api_response(status_code: int, body: Dict[str, Any]) -> Dict[str, Any]:
    """Helper function to format API Gateway response"""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",  # CORS support
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,OPTIONS",
        },
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    """AWS Lambda Handler"""
    conn = None  # Initialize connection to None

    try:
        logger.info(f"Received event: {json.dumps(event)}")

        # Parse query parameters
        query_params = event.get("queryStringParameters", {}) or {}

        # Validate query parameters
        validated_params, error = validate_query_parameters(query_params)
        if error:
            return api_response(400, {"error": error})

        limit = validated_params.get("limit", 10)

        # Connect to database
        conn = get_db_connection()

        # Get metrics
        readings_by_checkpoint = get_readings_by_checkpoint(conn)
        ads_by_campaign = get_ads_by_campaign(conn)
        recent_exposures = get_recent_exposures(conn, limit)

        # Return metrics
        return api_response(
            200,
            {
                "readings_by_checkpoint": readings_by_checkpoint,
                "ads_by_campaign": ads_by_campaign,
                "recent_exposures": recent_exposures,
                "metadata": {"limit_applied": limit},
            },
        )

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
