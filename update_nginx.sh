#!/bin/sh

# Esperar a que LocalStack esté listo
sleep 10

# Obtener el API ID desde el contenedor LocalStack
API_ID=$(docker exec localstack aws --endpoint-url=http://localhost:4566 apigateway get-rest-apis | docker exec localstack jq -r '.items[0].id')

# Verificar si API_ID se obtuvo correctamente
if [ -z "$API_ID" ] || [ "$API_ID" = "null" ]; then
  echo "Error: No se pudo obtener el API ID"
  exit 1
fi

# Crear la configuración de Nginx con la API ID dinámica
cat > /etc/nginx/nginx.conf <<EOF
events { }

http {
    server {
        listen 80;

        location /readings {
            proxy_pass http://localstack:4566/restapis/$API_ID/dev/_user_request_/readings;
        }

        location /metrics {
            proxy_pass http://localstack:4566/restapis/$API_ID/dev/_user_request_/metrics;
        }
    }
}
EOF

echo "✅ Configuración de Nginx actualizada con API ID: $API_ID"
