import json
import os
import psycopg2
import logging
from typing import Dict, Any, List

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Database connection parameters
DB_HOST = os.environ.get('DB_HOST', 'postgres')
DB_NAME = os.environ.get('DB_NAME', 'licenseplate_db')
DB_USER = os.environ.get('DB_USER', 'postgres')
DB_PASSWORD = os.environ.get('DB_PASSWORD', 'postgres')
DB_PORT = os.environ.get('DB_PORT', '5432')

def get_db_connection():
    """Establish a database connection"""
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            port=DB_PORT
        )
        return conn
    except Exception as e:
        logger.error(f"Database connection error: {e}")
        raise

def get_readings_by_checkpoint(conn) -> List[Dict[str, Any]]:
    """Get total readings count by checkpoint"""
    query = """
    SELECT checkpoint_id, COUNT(*) as total_readings
    FROM license_plate_readings
    GROUP BY checkpoint_id
    ORDER BY checkpoint_id
    """
    
    with conn.cursor() as cur:
        cur.execute(query)
        results = cur.fetchall()
        
        return [
            {
                "checkpoint_id": row[0],
                "total_readings": row[1]
            }
            for row in results
        ]

def get_ads_by_campaign(conn) -> List[Dict[str, Any]]:
    """Get total ads shown by campaign"""
    query = """
    SELECT campaign_id, COUNT(*) as total_ads_shown
    FROM ad_exposures
    GROUP BY campaign_id
    ORDER BY campaign_id
    """
    
    with conn.cursor() as cur:
        cur.execute(query)
        results = cur.fetchall()
        
        return [
            {
                "campaign_id": row[0],
                "total_ads_shown": row[1]
            }
            for row in results
        ]

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
    
    with conn.cursor() as cur:
        cur.execute(query, (limit,))
        results = cur.fetchall()
        
        return [
            {
                "exposure_id": row[0],
                "campaign_id": row[1],
                "ad_content": row[2],
                "timestamp": row[3].isoformat(),
                "reading_id": row[4],
                "license_plate": row[5],
                "checkpoint_id": row[6]
            }
            for row in results
        ]

def lambda_handler(event, context):
    """AWS Lambda Handler"""
    try:
        # Parse query parameters
        query_params = event.get('queryStringParameters', {}) or {}
        limit = int(query_params.get('limit', 10))
        
        # Connect to database
        conn = get_db_connection()
        
        # Get metrics
        readings_by_checkpoint = get_readings_by_checkpoint(conn)
        ads_by_campaign = get_ads_by_campaign(conn)
        recent_exposures = get_recent_exposures(conn, limit)
        
        conn.close()
        
        # Return metrics
        return {
            'statusCode': 200,
            'body': json.dumps({
                'readings_by_checkpoint': readings_by_checkpoint,
                'ads_by_campaign': ads_by_campaign,
                'recent_exposures': recent_exposures
            })
        }
        
    except Exception as e:
        logger.error(f"Error retrieving metrics: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': f'Internal server error: {str(e)}'})
        }
