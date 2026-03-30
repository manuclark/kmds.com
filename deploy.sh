#!/bin/bash
# ============================================================
# deploy.sh — Script de despliegue automático en EC2
# Uso: sudo bash deploy.sh <nombre-contenedor> <imagen> <puerto-interno> <subdominio>
# ============================================================

set -euo pipefail

# ── Parámetros ──
CONTAINER_NAME="${1:?❌ Falta parámetro: nombre del contenedor}"
IMAGE_NAME="${2:?❌ Falta parámetro: nombre de la imagen}"
INTERNAL_PORT="${3:?❌ Falta parámetro: puerto interno del contenedor}"
SUBDOMAIN="${4:?❌ Falta parámetro: subdominio}"

PORT_RANGE_START=8080
PORT_RANGE_END=8099

echo "══════════════════════════════════════════════════"
echo "🚀 Desplegando: $CONTAINER_NAME"
echo "   Imagen:    $IMAGE_NAME"
echo "   Puerto:    $INTERNAL_PORT (interno)"
echo "   Dominio:   $SUBDOMAIN"
echo "══════════════════════════════════════════════════"

# ── Paso 1: Detectar puertos en uso ──
echo ""
echo "🔍 Detectando puertos en uso..."
USED_PORTS=$(docker ps --format '{{.Ports}}' | grep -oP '0\.0\.0\.0:\K[0-9]+' | sort -n || true)

if [ -n "$USED_PORTS" ]; then
    echo "   Puertos ocupados: $(echo $USED_PORTS | tr '\n' ', ')"
else
    echo "   No hay puertos ocupados en el rango Docker"
fi

# ── Paso 2: Si el contenedor ya existe, reutilizar su puerto ──
AVAILABLE_PORT=""
EXISTING_PORT=$(docker port "$CONTAINER_NAME" 2>/dev/null | grep -oP '0\.0\.0\.0:\K[0-9]+' | head -1 || true)

if [ -n "$EXISTING_PORT" ]; then
    echo "♻️  Contenedor '$CONTAINER_NAME' ya existe en puerto $EXISTING_PORT — se reutilizará"
    AVAILABLE_PORT=$EXISTING_PORT
fi

# ── Paso 3: Encontrar primer puerto libre (si no se reutiliza) ──
if [ -z "$AVAILABLE_PORT" ]; then
    for PORT in $(seq $PORT_RANGE_START $PORT_RANGE_END); do
        if ! echo "$USED_PORTS" | grep -q "^${PORT}$"; then
            AVAILABLE_PORT=$PORT
            break
        fi
    done
fi

if [ -z "$AVAILABLE_PORT" ]; then
    echo "❌ ERROR: No hay puertos disponibles en el rango $PORT_RANGE_START-$PORT_RANGE_END"
    exit 1
fi

echo "✅ Puerto asignado: $AVAILABLE_PORT"

# ── Paso 4: Detener y eliminar contenedor anterior ──
echo ""
echo "🛑 Deteniendo contenedor anterior (si existe)..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# ── Paso 5: Ejecutar nuevo contenedor ──
echo ""
echo "🐳 Levantando contenedor..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "$AVAILABLE_PORT:$INTERNAL_PORT" \
    "$IMAGE_NAME"

echo "✅ Contenedor '$CONTAINER_NAME' corriendo en puerto $AVAILABLE_PORT -> $INTERNAL_PORT"

# ── Paso 6: Configurar Nginx reverse proxy ──
echo ""
echo "🌐 Configurando Nginx para $SUBDOMAIN..."

NGINX_CONF="/etc/nginx/sites-available/${SUBDOMAIN}.conf"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};

    location / {
        proxy_pass http://localhost:${AVAILABLE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo "   Archivo creado: $NGINX_CONF"

# ── Paso 7: Activar site y recargar Nginx ──
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"

echo "🔄 Validando configuración de Nginx..."
if nginx -t 2>&1; then
    systemctl reload nginx
    echo "✅ Nginx recargado correctamente"
else
    echo "❌ ERROR: Configuración de Nginx inválida"
    exit 1
fi

# ── Paso 8: Health check ──
echo ""
echo "💓 Verificando salud del contenedor..."
sleep 5

if curl -sf --max-time 10 "http://localhost:${AVAILABLE_PORT}" > /dev/null; then
    echo "✅ Health check exitoso — el servicio responde en puerto $AVAILABLE_PORT"
else
    echo "⚠️  Health check falló — el contenedor puede necesitar más tiempo para iniciar"
    echo "   Verificar manualmente: curl http://localhost:${AVAILABLE_PORT}"
fi

# ── Resumen ──
echo ""
echo "══════════════════════════════════════════════════"
echo "✅ DESPLIEGUE COMPLETADO"
echo "   Contenedor:  $CONTAINER_NAME"
echo "   Puerto:      $AVAILABLE_PORT -> $INTERNAL_PORT"
echo "   Dominio:     http://$SUBDOMAIN"
echo "══════════════════════════════════════════════════"
