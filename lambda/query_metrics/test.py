import unittest
from unittest.mock import patch, MagicMock
import json
import datetime
import sys
import os

# Importar el módulo de la lambda
from app import (
    validate_query_parameters,
    get_readings_by_checkpoint,
    get_ads_by_campaign,
    get_recent_exposures,
    lambda_handler,
    DatabaseError,
    ValidationError,
)


class TestQueryMetricsLambda(unittest.TestCase):

    def setUp(self):
        # Mock de conexión a la base de datos
        self.mock_conn = MagicMock()
        self.mock_cursor = MagicMock()
        self.mock_conn.cursor.return_value.__enter__.return_value = self.mock_cursor

        # Datos de muestra para pruebas
        self.sample_readings = [("CHECK_01", 5), ("CHECK_02", 3)]

        self.sample_campaigns = [("CAMP_001", 7), ("CAMP_002", 2)]

        self.sample_exposures = [
            (
                1,
                "CAMP_001",
                "AD_001",
                datetime.datetime(2023, 6, 10, 14, 30),
                "READ_001",
                "ABC123",
                "CHECK_01",
            ),
            (
                2,
                "CAMP_001",
                "AD_001",
                datetime.datetime(2023, 6, 10, 15, 30),
                "READ_002",
                "DEF456",
                "CHECK_02",
            ),
        ]

    def test_validate_query_parameters_valid(self):
        # Probar parámetros válidos
        params, error = validate_query_parameters({"limit": "10"})
        self.assertEqual(params["limit"], 10)
        self.assertIsNone(error)

        # Probar sin parámetros (debe usar valores por defecto)
        params, error = validate_query_parameters({})
        self.assertEqual(params["limit"], 10)
        self.assertIsNone(error)

    def test_validate_query_parameters_invalid(self):
        # Probar límite negativo
        params, error = validate_query_parameters({"limit": "-5"})
        self.assertEqual(params, {})
        self.assertIsNotNone(error)

        # Probar límite no numérico
        params, error = validate_query_parameters({"limit": "abc"})
        self.assertEqual(params, {})
        self.assertIsNotNone(error)

    def test_validate_query_parameters_exceeding_max(self):
        # Probar límite que excede el máximo permitido
        from app import MAX_ALLOWED_LIMIT

        params, error = validate_query_parameters(
            {"limit": str(MAX_ALLOWED_LIMIT + 50)}
        )
        self.assertEqual(params["limit"], MAX_ALLOWED_LIMIT)
        self.assertIsNone(error)

    def test_get_readings_by_checkpoint(self):
        # Configurar mock para devolver datos de muestra
        self.mock_cursor.fetchall.return_value = self.sample_readings

        # Llamar a la función
        result = get_readings_by_checkpoint(self.mock_conn)

        # Verificar resultado
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["checkpoint_id"], "CHECK_01")
        self.assertEqual(result[0]["total_readings"], 5)
        self.assertEqual(result[1]["checkpoint_id"], "CHECK_02")
        self.assertEqual(result[1]["total_readings"], 3)

        # Verificar que se llamó al execute
        self.mock_cursor.execute.assert_called_once()

    def test_get_ads_by_campaign(self):
        # Configurar mock para devolver datos de muestra
        self.mock_cursor.fetchall.return_value = self.sample_campaigns

        # Llamar a la función
        result = get_ads_by_campaign(self.mock_conn)

        # Verificar resultado
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["campaign_id"], "CAMP_001")
        self.assertEqual(result[0]["total_ads_shown"], 7)
        self.assertEqual(result[1]["campaign_id"], "CAMP_002")
        self.assertEqual(result[1]["total_ads_shown"], 2)

        # Verificar que se llamó al execute
        self.mock_cursor.execute.assert_called_once()

    def test_get_recent_exposures(self):
        # Configurar mock para devolver datos de muestra
        self.mock_cursor.fetchall.return_value = self.sample_exposures

        # Llamar a la función con límite predeterminado
        result = get_recent_exposures(self.mock_conn)

        # Verificar resultado
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["exposure_id"], 1)
        self.assertEqual(result[0]["campaign_id"], "CAMP_001")
        self.assertEqual(result[0]["ad_content"], "AD_001")
        self.assertEqual(result[0]["reading_id"], "READ_001")
        self.assertEqual(result[0]["license_plate"], "ABC123")
        self.assertEqual(result[0]["checkpoint_id"], "CHECK_01")

        # Verificar límite personalizado
        self.mock_cursor.reset_mock()
        get_recent_exposures(self.mock_conn, 5)
        args, _ = self.mock_cursor.execute.call_args
        self.assertEqual(args[1], (5,))  # Verificar que se pasó el límite correcto

    @patch("app.get_db_connection")
    @patch("app.get_readings_by_checkpoint")
    @patch("app.get_ads_by_campaign")
    @patch("app.get_recent_exposures")
    def test_lambda_handler_valid_params(
        self, mock_exposures, mock_campaigns, mock_readings, mock_get_conn
    ):
        # Configurar mocks
        mock_get_conn.return_value = self.mock_conn
        mock_readings.return_value = [
            {"checkpoint_id": "CHECK_01", "total_readings": 5}
        ]
        mock_campaigns.return_value = [
            {"campaign_id": "CAMP_001", "total_ads_shown": 7}
        ]
        mock_exposures.return_value = [
            {
                "exposure_id": 1,
                "campaign_id": "CAMP_001",
                "ad_content": "AD_001",
                "timestamp": "2023-06-10T14:30:00",
                "reading_id": "READ_001",
                "license_plate": "ABC123",
                "checkpoint_id": "CHECK_01",
            }
        ]

        # Crear evento de API Gateway
        event = {"queryStringParameters": {"limit": "5"}}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta
        self.assertEqual(response["statusCode"], 200)
        body = json.loads(response["body"])
        self.assertIn("readings_by_checkpoint", body)
        self.assertIn("ads_by_campaign", body)
        self.assertIn("recent_exposures", body)
        self.assertEqual(body["metadata"]["limit_applied"], 5)

        # Verificar que se llamaron los métodos correctos
        mock_readings.assert_called_once()
        mock_campaigns.assert_called_once()
        mock_exposures.assert_called_once_with(self.mock_conn, 5)

    @patch("app.get_db_connection")
    def test_lambda_handler_invalid_params(self, mock_get_conn):
        # Configurar mock
        mock_get_conn.return_value = self.mock_conn

        # Crear evento de API Gateway con parámetros inválidos
        event = {"queryStringParameters": {"limit": "-5"}}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta de error
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("error", json.loads(response["body"]))

    @patch("app.get_db_connection")
    @patch("app.get_readings_by_checkpoint")
    def test_lambda_handler_database_error(self, mock_readings, mock_get_conn):
        # Configurar mock para lanzar error de base de datos
        mock_get_conn.return_value = self.mock_conn
        mock_readings.side_effect = DatabaseError("Error de conexión")

        # Crear evento de API Gateway
        event = {"queryStringParameters": {"limit": "10"}}

        # Llamar al handler
        response = lambda_handler(event, {})

        # Verificar respuesta de error
        self.assertEqual(response["statusCode"], 500)
        self.assertIn("Database error", json.loads(response["body"])["error"])


if __name__ == "__main__":
    unittest.main()
