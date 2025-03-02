import unittest
from unittest.mock import patch, MagicMock
import json
import datetime
import sys
import os

# Importar el módulo de la lambda
from app import (
    validate_reading,
    is_in_time_window,
    determine_applicable_campaign,
    save_reading,
    get_exposure_count,
    lambda_handler,
    DatabaseError,
    ValidationError,
)


class TestProcessReadingsLambda(unittest.TestCase):

    def setUp(self):
        # Datos de prueba
        self.valid_reading = {
            "reading_id": "TEST_001",
            "timestamp": "2023-06-10T14:30:00Z",
            "license_plate": "ABC123",
            "checkpoint_id": "CHECK_01",
            "location": {"latitude": 37.7749, "longitude": -122.4194},
        }

        self.mock_conn = MagicMock()
        self.mock_cursor = MagicMock()
        self.mock_conn.cursor.return_value.__enter__.return_value = self.mock_cursor

        # Mock de la campaña para pruebas
        self.test_campaign = {
            "campaign_id": "CAMP_001",
            "locations": ["CHECK_01", "CHECK_02"],
            "time_window": {"start": "08:00", "end": "20:00"},
            "max_exposures_per_plate": 3,
            "ad_content": "AD_001",
        }

    def test_validate_reading_valid(self):
        # Probar lectura válida
        is_valid, error = validate_reading(self.valid_reading)
        self.assertTrue(is_valid)
        self.assertIsNone(error)

    def test_validate_reading_missing_field(self):
        # Probar lectura con campo faltante
        invalid_reading = self.valid_reading.copy()
        del invalid_reading["checkpoint_id"]
        is_valid, error = validate_reading(invalid_reading)
        self.assertFalse(is_valid)
        self.assertIn("checkpoint_id", error)

    def test_validate_reading_invalid_timestamp(self):
        # Probar timestamp inválido
        invalid_reading = self.valid_reading.copy()
        invalid_reading["timestamp"] = "10-06-2023"
        is_valid, error = validate_reading(invalid_reading)
        self.assertFalse(is_valid)
        self.assertIn("timestamp", error)

    def test_validate_reading_invalid_location(self):
        # Probar ubicación inválida
        invalid_reading = self.valid_reading.copy()
        invalid_reading["location"] = {
            "latitude": "not-a-number",
            "longitude": -122.4194,
        }
        is_valid, error = validate_reading(invalid_reading)
        self.assertFalse(is_valid)
        self.assertIn("location", error)

        # Probar ubicación fuera de rango
        invalid_reading = self.valid_reading.copy()
        invalid_reading["location"] = {"latitude": 100, "longitude": -122.4194}
        is_valid, error = validate_reading(invalid_reading)
        self.assertFalse(is_valid)
        self.assertIn("latitude", error)

    def test_is_in_time_window(self):
        # Probar dentro de la ventana de tiempo
        reading_time = datetime.datetime(2023, 6, 10, 14, 30, 0)
        self.assertTrue(is_in_time_window(reading_time, "08:00", "20:00"))

        # Probar fuera de la ventana de tiempo
        reading_time = datetime.datetime(2023, 6, 10, 7, 30, 0)
        self.assertFalse(is_in_time_window(reading_time, "08:00", "20:00"))

        # Probar en el límite de la ventana
        reading_time = datetime.datetime(2023, 6, 10, 8, 0, 0)
        self.assertTrue(is_in_time_window(reading_time, "08:00", "20:00"))

        # Probar con formato inválido debe devolver False sin lanzar excepción
        reading_time = datetime.datetime(2023, 6, 10, 14, 30, 0)
        self.assertFalse(is_in_time_window(reading_time, "invalid", "20:00"))

    @patch("app.get_exposure_count")
    def test_determine_applicable_campaign(self, mock_get_exposure_count):
        # Mockear get_exposure_count para devolver 0 (por debajo del límite)
        mock_get_exposure_count.return_value = 0

        # Probar checkpoint y hora dentro de campaña
        result = determine_applicable_campaign(self.mock_conn, self.valid_reading)
        self.assertIsNotNone(result)
        self.assertEqual(result["campaign_id"], "CAMP_001")

        # Probar checkpoint fuera de campaña
        invalid_reading = self.valid_reading.copy()
        invalid_reading["checkpoint_id"] = "CHECK_05"
        result = determine_applicable_campaign(self.mock_conn, invalid_reading)
        self.assertIsNone(result)

        # Probar hora fuera de campaña
        invalid_reading = self.valid_reading.copy()
        invalid_reading["timestamp"] = "2023-06-10T07:30:00Z"
        result = determine_applicable_campaign(self.mock_conn, invalid_reading)
        self.assertIsNone(result)

        # Probar exposiciones excedidas
        mock_get_exposure_count.return_value = 5
        result = determine_applicable_campaign(self.mock_conn, self.valid_reading)
        self.assertIsNone(result)

    def test_save_reading(self):
        # Probar guardar lectura
        save_reading(self.mock_conn, self.valid_reading)

        # Verificar que se llamó al execute con los parámetros correctos
        self.mock_cursor.execute.assert_called_once()
        args, _ = self.mock_cursor.execute.call_args
        query = args[0]
        params = args[1]

        self.assertIn("INSERT INTO license_plate_readings", query)
        self.assertEqual(params[0], self.valid_reading["reading_id"])
        self.assertEqual(params[1], self.valid_reading["timestamp"])
        self.assertEqual(params[2], self.valid_reading["license_plate"])

    def test_get_exposure_count(self):
        # Configurar mock para devolver un recuento
        self.mock_cursor.fetchone.return_value = [2]

        # Probar obtener conteo de exposiciones
        count = get_exposure_count(self.mock_conn, "ABC123", "CAMP_001")

        # Verificar llamada y resultado
        self.mock_cursor.execute.assert_called_once()
        self.assertEqual(count, 2)

    @patch("app.get_db_connection")
    @patch("app.save_reading")
    @patch("app.determine_applicable_campaign")
    @patch("app.save_exposure")
    def test_lambda_handler_valid_reading(
        self,
        mock_save_exposure,
        mock_determine_campaign,
        mock_save_reading,
        mock_get_conn,
    ):
        # Configurar mocks
        mock_get_conn.return_value = self.mock_conn
        mock_determine_campaign.return_value = self.test_campaign

        # Crear evento de API Gateway
        event = {"body": json.dumps(self.valid_reading)}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta
        self.assertEqual(response["statusCode"], 200)
        body = json.loads(response["body"])
        self.assertTrue(body["processed"])
        self.assertEqual(body["reading_id"], self.valid_reading["reading_id"])
        self.assertEqual(
            body["ad_served"]["campaign_id"], self.test_campaign["campaign_id"]
        )

        # Verificar que se llamaron los métodos correctos
        mock_save_reading.assert_called_once()
        mock_determine_campaign.assert_called_once()
        mock_save_exposure.assert_called_once()

    @patch("app.get_db_connection")
    @patch("app.save_reading")
    def test_lambda_handler_invalid_reading(self, mock_save_reading, mock_get_conn):
        # Configurar mock
        mock_get_conn.return_value = self.mock_conn

        # Crear evento de API Gateway con lectura inválida
        invalid_reading = self.valid_reading.copy()
        del invalid_reading["checkpoint_id"]
        event = {"body": json.dumps(invalid_reading)}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta de error
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("error", json.loads(response["body"]))

        # Verificar que no se llamó a save_reading
        mock_save_reading.assert_not_called()

    @patch("app.get_db_connection")
    @patch("app.save_reading")
    def test_lambda_handler_no_applicable_campaign(
        self, mock_save_reading, mock_get_conn
    ):
        # Configurar mocks
        mock_get_conn.return_value = self.mock_conn

        # Crear evento con checkpoint fuera de campaña
        invalid_reading = self.valid_reading.copy()
        invalid_reading["checkpoint_id"] = "CHECK_05"
        event = {"body": json.dumps(invalid_reading)}

        # Llamar al handler con parchado interno para determine_applicable_campaign
        with patch("app.determine_applicable_campaign", return_value=None):
            response = lambda_handler(event, {})

        # Verificar respuesta
        self.assertEqual(response["statusCode"], 200)
        body = json.loads(response["body"])
        self.assertTrue(body["processed"])
        self.assertIsNone(body["ad_served"])

    @patch("app.get_db_connection")
    @patch("app.save_reading")
    def test_lambda_handler_database_error(self, mock_save_reading, mock_get_conn):
        # Configurar mock para lanzar error de base de datos
        mock_save_reading.side_effect = DatabaseError("Error de conexión")
        mock_get_conn.return_value = self.mock_conn

        # Crear evento de API Gateway
        event = {"body": json.dumps(self.valid_reading)}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta de error
        self.assertEqual(response["statusCode"], 500)
        self.assertIn("Database error", json.loads(response["body"])["error"])


if __name__ == "__main__":
    unittest.main()
