-- Create tables for license plate readings and ad exposures

-- Table for license plate readings
CREATE TABLE IF NOT EXISTS license_plate_readings (
    id SERIAL PRIMARY KEY,
    reading_id VARCHAR(50) UNIQUE NOT NULL,
    timestamp TIMESTAMP NOT NULL,
    license_plate VARCHAR(20) NOT NULL,
    checkpoint_id VARCHAR(50) NOT NULL,
    latitude DECIMAL(10, 8) NOT NULL,
    longitude DECIMAL(11, 8) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Table for ad exposures
CREATE TABLE IF NOT EXISTS ad_exposures (
    id SERIAL PRIMARY KEY,
    reading_id VARCHAR(50) NOT NULL REFERENCES license_plate_readings(reading_id),
    campaign_id VARCHAR(50) NOT NULL,
    ad_content VARCHAR(50) NOT NULL,
    exposure_timestamp TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX idx_readings_checkpoint ON license_plate_readings(checkpoint_id);
CREATE INDEX idx_readings_license_plate ON license_plate_readings(license_plate);
CREATE INDEX idx_exposures_campaign ON ad_exposures(campaign_id);
