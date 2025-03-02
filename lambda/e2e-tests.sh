#!/bin/bash

# Colores para mejor visualización
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuración
API_ID=$(docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis | grep "id" | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')
BASE_URL="http://localhost:4566/restapis/$API_ID/dev/_user_request_"
READINGS_ENDPOINT="$BASE_URL/readings"
METRICS_ENDPOINT="$BASE_URL/metrics"

# Función para imprimir mensajes formateados
print_message() {
  local type=$1
  local message=$2
  
  if [ "$type" == "info" ]; then
    echo -e "${YELLOW}INFO:${NC} $message"
  elif [ "$type" == "success" ]; then
    echo -e "${GREEN}SUCCESS:${NC} $message"
  elif [ "$type" == "error" ]; then
    echo -e "${RED}ERROR:${NC} $message"
  fi
}

# Función para realizar solicitudes HTTP y validar respuestas
make_request() {
  local test_name=$1
  local method=$2
  local url=$3
  local data=$4
  local expected_status=$5
  local validation_key=$6
  local validation_value=$7
  
  print_message "info" "Ejecutando prueba: $test_name"
  
  if [ "$method" == "GET" ]; then
    response=$(curl -s -w "\n%{http_code}" -X GET "$url")
  else
    response=$(curl -s -w "\n%{http_code}" -X POST "$url" -H "Content-Type: application/json" -d "$data")
  fi
  
  # Extraer el código de estado y el cuerpo de la respuesta
  status_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  
  # Validar el código de estado
  if [ "$status_code" != "$expected_status" ]; then
    print_message "error" "Código de estado incorrecto. Esperado: $expected_status, Recibido: $status_code"
    print_message "error" "Respuesta: $body"
    return 1
  fi
  
  # Validar el contenido de la respuesta si se proporcionaron parámetros de validación
  if [ -n "$validation_key" ] && [ -n "$validation_value" ]; then
    # Si validation_value contiene corchetes, usamos una validación simple
    if [[ "$validation_value" == *"["* || "$validation_value" == *"]"* ]]; then
      # Solo verificamos que la clave exista en el JSON
      if ! echo "$body" | grep -q "\"$validation_key\""; then
        print_message "error" "Validación fallida. No se encontró \"$validation_key\" en la respuesta"
        print_message "error" "Respuesta: $body"
        return 1
      fi
    else
      # Validación normal para valores sin corchetes
      if ! echo "$body" | grep -q "\"$validation_key\"[[:space:]]*:[[:space:]]*$validation_value"; then
        print_message "error" "Validación fallida. No se encontró \"$validation_key\": $validation_value"
        print_message "error" "Respuesta: $body"
        return 1
      fi
    fi
  fi
  
  print_message "success" "Prueba completada exitosamente"
  return 0
}

# Función para verificar la conexión a la base de datos
check_database() {
  print_message "info" "Verificando conexión a la base de datos..."
  if docker exec postgres psql -U postgres -d licenseplate_db -c "SELECT 1" > /dev/null 2>&1; then
    print_message "success" "Conexión a la base de datos establecida"
    return 0
  else
    print_message "error" "No se pudo conectar a la base de datos"
    return 1
  fi
}

# Función para limpiar la base de datos antes de las pruebas
clean_database() {
  print_message "info" "Limpiando la base de datos para pruebas limpias..."
  docker exec postgres psql -U postgres -d licenseplate_db -c "DELETE FROM ad_exposures; DELETE FROM license_plate_readings;"
  print_message "success" "Base de datos limpiada"
}

# Verificar que el entorno está en funcionamiento
print_message "info" "Verificando que el entorno está en funcionamiento..."

if [ -z "$API_ID" ]; then
  print_message "error" "No se pudo obtener el API ID. Asegúrate de que LocalStack esté funcionando."
  exit 1
fi

print_message "success" "API ID obtenido: $API_ID"

# Verificar conexión a la base de datos
check_database || exit 1

# Limpiar la base de datos antes de las pruebas
clean_database

# Conjunto de pruebas E2E

# TEST 1: Procesar una lectura válida para una campaña aplicable (CHECK_01)
print_message "info" "TEST 1: Procesar una lectura válida para una campaña aplicable (CHECK_01)"
data_test_1='{
  "reading_id": "TEST_READ_001",
  "timestamp": "2023-06-10T14:30:00Z",
  "license_plate": "ABC123",
  "checkpoint_id": "CHECK_01",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Lectura válida en CHECK_01" "POST" "$READINGS_ENDPOINT" "$data_test_1" 200 "ad_served" "{"

# TEST 2: Procesar otra lectura válida para la misma patente pero en diferente checkpoint de la misma campaña
print_message "info" "TEST 2: Procesar otra lectura válida para la misma patente pero en diferente checkpoint de la misma campaña"
data_test_2='{
  "reading_id": "TEST_READ_002",
  "timestamp": "2023-06-10T15:30:00Z",
  "license_plate": "ABC123",
  "checkpoint_id": "CHECK_02",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Misma patente, diferente checkpoint" "POST" "$READINGS_ENDPOINT" "$data_test_2" 200 "ad_served" "{"

# TEST 3: Procesar una lectura para un checkpoint fuera de cualquier campaña
print_message "info" "TEST 3: Procesar una lectura para un checkpoint fuera de cualquier campaña"
data_test_3='{
  "reading_id": "TEST_READ_003",
  "timestamp": "2023-06-10T14:30:00Z",
  "license_plate": "XYZ789",
  "checkpoint_id": "CHECK_05",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Checkpoint fuera de campaña" "POST" "$READINGS_ENDPOINT" "$data_test_3" 200 "ad_served" "null"

# TEST 4: Procesar una lectura dentro de un checkpoint de campaña pero fuera del horario
print_message "info" "TEST 4: Procesar una lectura dentro de un checkpoint de campaña pero fuera del horario"
data_test_4='{
  "reading_id": "TEST_READ_004",
  "timestamp": "2023-06-10T07:30:00Z",
  "license_plate": "DEF456",
  "checkpoint_id": "CHECK_01",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Fuera del horario de campaña" "POST" "$READINGS_ENDPOINT" "$data_test_4" 200 "ad_served" "null"

# TEST 5: Exceder el límite de exposiciones por patente
print_message "info" "TEST 5: Exceder el límite de exposiciones por patente"

# Primero, enviamos 3 lecturas para alcanzar el límite
for i in {1..3}; do
  reading_id="TEST_READ_005_$i"
  data='{
    "reading_id": "'$reading_id'",
    "timestamp": "2023-06-10T14:30:00Z",
    "license_plate": "LMT123",
    "checkpoint_id": "CHECK_01",
    "location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    }
  }'
  make_request "Lectura $i para límite de exposiciones" "POST" "$READINGS_ENDPOINT" "$data" 200 "ad_served" "{"
done

# Ahora enviamos una cuarta lectura que debería superar el límite
data_test_5_4='{
  "reading_id": "TEST_READ_005_4",
  "timestamp": "2023-06-10T14:45:00Z",
  "license_plate": "LMT123",
  "checkpoint_id": "CHECK_01",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Exceder límite de exposiciones" "POST" "$READINGS_ENDPOINT" "$data_test_5_4" 200 "ad_served" "null"

# TEST 6: Intentar procesar una lectura con ID duplicado
print_message "info" "TEST 6: Intentar procesar una lectura con ID duplicado"
make_request "ID de lectura duplicado" "POST" "$READINGS_ENDPOINT" "$data_test_1" 409 "error" "\"Duplicate"

# TEST 7: Enviar datos inválidos (falta campo obligatorio)
print_message "info" "TEST 7: Enviar datos inválidos (falta campo obligatorio)"
data_test_7='{
  "reading_id": "TEST_READ_007",
  "timestamp": "2023-06-10T14:30:00Z",
  "license_plate": "ABC123",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Falta campo obligatorio" "POST" "$READINGS_ENDPOINT" "$data_test_7" 400 "error" "\""

# TEST 8: Enviar timestamp con formato inválido
print_message "info" "TEST 8: Enviar timestamp con formato inválido"
data_test_8='{
  "reading_id": "TEST_READ_008",
  "timestamp": "10-06-2023",
  "license_plate": "ABC123",
  "checkpoint_id": "CHECK_01",
  "location": {
    "latitude": 37.7749,
    "longitude": -122.4194
  }
}'
make_request "Timestamp inválido" "POST" "$READINGS_ENDPOINT" "$data_test_8" 400 "error" "\""

# TEST 9: Consultar métricas básicas
print_message "info" "TEST 9: Consultar métricas básicas"
make_request "Consulta de métricas" "GET" "$METRICS_ENDPOINT" "" 200 "readings_by_checkpoint" "["

# TEST 10: Consultar métricas con límite personalizado
print_message "info" "TEST 10: Consultar métricas con límite personalizado"
make_request "Métricas con límite" "GET" "$METRICS_ENDPOINT?limit=2" "" 200 "limit_applied" "2"

# TEST 11: Consultar métricas con límite inválido
print_message "info" "TEST 11: Consultar métricas con límite inválido"
make_request "Métricas con límite inválido" "GET" "$METRICS_ENDPOINT?limit=-1" "" 400 "error" "\""

# TEST 12: Procesamiento de lecturas en lote
print_message "info" "TEST 12: Verificar consistencia después de procesamiento en lote"

# Enviamos 10 lecturas rápidamente
for i in {1..10}; do
  reading_id="TEST_READ_BATCH_$i"
  license_plate="BATCH$i"
  checkpoint="CHECK_01"
  if [ $((i % 2)) -eq 0 ]; then
    checkpoint="CHECK_02"
  fi
  data='{
    "reading_id": "'$reading_id'",
    "timestamp": "2023-06-10T14:30:00Z",
    "license_plate": "'$license_plate'",
    "checkpoint_id": "'$checkpoint'",
    "location": {
      "latitude": 37.7749,
      "longitude": -122.4194
    }
  }'
  make_request "Lectura batch $i" "POST" "$READINGS_ENDPOINT" "$data" 200 "processed" "true"
done

# Verificamos las métricas para confirmar consistencia
make_request "Verificar consistencia después de batch" "GET" "$METRICS_ENDPOINT" "" 200 "readings_by_checkpoint" "["

# Verificación final en la base de datos
print_message "info" "Verificando los datos en la base de datos..."
docker exec postgres psql -U postgres -d licenseplate_db -c "SELECT count(*) FROM license_plate_readings"
docker exec postgres psql -U postgres -d licenseplate_db -c "SELECT count(*) FROM ad_exposures"

print_message "success" "Todas las pruebas E2E han sido completadas"