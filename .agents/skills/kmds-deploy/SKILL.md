---
name: kmds-deploy
description: >
  Pipeline CI/CD completo para el proyecto kmds.com: construir imagen Docker,
  desplegar en AWS EC2 mediante GitHub Actions, gestionar puertos dinámicos,
  configurar Nginx como reverse proxy, configurar DNS en Cloudflare y habilitar
  HTTPS gratuito con Origin Certificate de Cloudflare. Úsalo cuando el usuario
  pida ayuda con despliegue, CI/CD, Nginx, DNS, HTTPS o cualquier tarea
  relacionada con la infraestructura del proyecto kmds.
tags:
  - cicd
  - docker
  - github-actions
  - aws-ec2
  - nginx
  - cloudflare
  - https
  - deploy
---

# Skill: kmds-deploy

## Contexto general

Este skill documenta la arquitectura, procedimientos y decisiones de la
infraestructura de despliegue del proyecto **kmds.com**. Está diseñado para
ser usado por un LLM como contexto de referencia al asistir en tareas de
mantenimiento, diagnóstico, ampliación o reconfiguración del pipeline.

### Stack de infraestructura

| Componente | Tecnología |
|---|---|
| Servidor | AWS EC2 — Ubuntu 24.04 LTS |
| Contenedores | Docker |
| Reverse proxy | Nginx |
| Pipeline CI/CD | GitHub Actions (GitHub-hosted runner) |
| DNS | Cloudflare |
| SSL/TLS | Cloudflare Origin Certificate (gratuito, válido 15 años) |

### Datos sensibles requeridos

Los valores sensibles **nunca** se almacenan en el repositorio. Se configuran
como **GitHub Secrets** y se referencian en los workflows con la sintaxis
`${{ secrets.NOMBRE }}`. Para obtenerlos:

| Variable | Cómo obtenerla |
|---|---|
| `EC2_HOST` | IP pública de la instancia EC2 en la consola de AWS → EC2 → Instances |
| `EC2_USER` | Usuario del sistema operativo de la instancia (ej: `ubuntu` para Ubuntu AMI) |
| `EC2_SSH_KEY` | Contenido completo del archivo `.pem` de la key pair usada al crear la instancia EC2 |
| `CLOUDFLARE_API_TOKEN` | Cloudflare Dashboard → Profile → [API Tokens](https://dash.cloudflare.com/profile/api-tokens) → Create Token → plantilla "Edit zone DNS" |
| `CLOUDFLARE_ZONE_ID` | Cloudflare Dashboard → seleccionar dominio → Overview → columna derecha → "Zone ID" |

---

## Sección 1 — Arquitectura del pipeline

### Flujo general

```
[GitHub Repo] → push a rama (main / develop)
       ↓
[GitHub Actions — ubuntu-latest runner]
       ↓
  1. Checkout del código
  2. Definir variables según rama (nombre contenedor, subdominio, imagen)
  3. Build de la imagen Docker
  4. Copiar imagen al servidor via SCP (solo image.tar.gz)
  5. Ejecutar lógica de despliegue en el servidor via SSH (inlineada en el workflow)
       a. Cargar imagen Docker
       b. Reusar puerto existente del contenedor (si ya existe)
       c. Buscar primer puerto libre en rango 8080–8099 (si es nuevo)
       d. Detener y eliminar contenedor anterior
       e. Levantar nuevo contenedor con puerto disponible
       f. Generar/actualizar config Nginx (HTTP + HTTPS)
       g. Activar site y recargar Nginx
       h. Verificar salud del contenedor
```

### Mapeo de ramas y entornos

| Rama Git | Contenedor Docker | Subdominio | Puerto interno |
|---|---|---|---|
| `main` | `kmds` | `kmdatasolutions.com` | `80` |
| `develop` | `kmds-develop` | `dev.kmdatasolutions.com` | `80` |

### Rango de puertos en el host

Los contenedores Docker usan el rango **8080–8099** en el host.
`deploy.sh` detecta automáticamente el primer puerto libre y lo asigna.

| Puerto | Servicio |
|---|---|
| 22 | SSH |
| 53 | DNS local |
| 80 | Nginx (redirect a HTTPS) |
| 443 | Nginx (HTTPS) |
| 8080 | Docker: kmds (main) |
| 8081 | Docker: reservado |
| 8082 | Docker: reservado |
| 8083 | Docker: kmds-develop |
| 8084–8099 | Disponibles para nuevos proyectos |
| 27017 | MongoDB (acceso solo local) |

---

## Sección 2 — Estructura de archivos del repositorio

```
repositorio/
├── .github/
│   └── workflows/
│       └── deploy.yml     ← Workflow de CI/CD (lógica de despliegue inlineada)
├── .agents/
│   └── skills/
│       └── kmds-deploy/
│           └── SKILL.md   ← Este archivo
├── Dockerfile             ← Build de la imagen Docker
└── ...                    ← Código fuente del proyecto
```

> **Nota:** `deploy.sh` fue eliminado. Toda la lógica de despliegue está inlineada
> en el paso SSH del workflow, lo que simplifica el repositorio y elimina la
> dependencia de que el archivo esté presente en cada commit.

---

## Sección 3 — Dockerfile

- Definir la imagen base según la tecnología del proyecto.
- Exponer el **puerto interno** de la app (ej: `EXPOSE 80`).
- Considerar multi-stage build para reducir tamaño.

Ejemplo mínimo para una app que sirve en el puerto 80:

```dockerfile
FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80
```

---

## Sección 4 — Lógica de despliegue (inlineada en el workflow)

> `deploy.sh` fue eliminado del repositorio. La lógica equivalente está inlineada
> directamente en el paso SSH de `.github/workflows/deploy.yml`.

### Lógica del script SSH

```bash
set -euo pipefail

CONTAINER_NAME="<nombre-contenedor>"
IMAGE_NAME="<imagen>:latest"
INTERNAL_PORT="80"
SUBDOMAIN="<subdominio>"

# Cargar imagen
cd /tmp/deploy
gunzip -c image.tar.gz | docker load
rm -rf /tmp/deploy

# Reusar puerto actual si el contenedor ya existe
# Nota: | head -1 evita que docker port retorne dos líneas (IPv4 + IPv6)
CURRENT_PORT=$(docker port "$CONTAINER_NAME" "$INTERNAL_PORT" 2>/dev/null | grep -oP ':\K[0-9]+' | head -1 || true)

if [ -n "$CURRENT_PORT" ]; then
  AVAILABLE_PORT=$CURRENT_PORT
else
  # Buscar primer puerto libre en el rango 8080–8099
  USED_PORTS=$(docker ps --format '{{.Ports}}' | grep -oP '0\.0\.0\.0:\K[0-9]+' | sort -n)
  AVAILABLE_PORT=""
  for PORT in $(seq 8080 8099); do
    if ! echo "$USED_PORTS" | grep -q "^$PORT$"; then
      AVAILABLE_PORT=$PORT
      break
    fi
  done
  if [ -z "$AVAILABLE_PORT" ]; then
    echo "❌ No hay puertos disponibles en el rango 8080-8099"
    exit 1
  fi
fi

# Detener y eliminar contenedor anterior
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm   "$CONTAINER_NAME" 2>/dev/null || true

# Levantar nuevo contenedor
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "$AVAILABLE_PORT:$INTERNAL_PORT" \
  "$IMAGE_NAME"

# Generar configuración Nginx (HTTP redirect + HTTPS proxy)
sudo tee /etc/nginx/sites-available/"$SUBDOMAIN".conf > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SUBDOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $SUBDOMAIN;

    ssl_certificate     /etc/ssl/cloudflare/origin.pem;
    ssl_certificate_key /etc/ssl/cloudflare/origin-key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://localhost:$AVAILABLE_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF

# Activar site y recargar Nginx
sudo ln -sf /etc/nginx/sites-available/"$SUBDOMAIN".conf \
            /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Health check
sleep 5
curl -sf http://localhost:"$AVAILABLE_PORT"/ -o /dev/null \
  && echo "✅ $CONTAINER_NAME desplegado en puerto $AVAILABLE_PORT" \
  || echo "⚠️ Health check falló — verificar manualmente"
```

---

## Sección 5 — Workflow `.github/workflows/deploy.yml`

```yaml
name: Deploy to EC2

on:
  push:
    branches:
      - main
      - develop

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout código
        uses: actions/checkout@v4

      - name: Definir variables según rama
        id: vars
        run: |
          if [ "${{ github.ref_name }}" = "main" ]; then
            echo "container_name=kmds"                       >> $GITHUB_OUTPUT
            echo "subdomain=kmdatasolutions.com"             >> $GITHUB_OUTPUT
            echo "image_name=kmds:latest"                    >> $GITHUB_OUTPUT
          else
            echo "container_name=kmds-develop"               >> $GITHUB_OUTPUT
            echo "subdomain=dev.kmdatasolutions.com"         >> $GITHUB_OUTPUT
            echo "image_name=kmds-develop:latest"            >> $GITHUB_OUTPUT
          fi

      - name: Build imagen Docker
        run: |
          docker build -t ${{ steps.vars.outputs.image_name }} .
          docker save ${{ steps.vars.outputs.image_name }} | gzip > image.tar.gz

      - name: Copiar imagen al servidor
        uses: appleboy/scp-action@v0.1.7
        with:
          host:     ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key:      ${{ secrets.EC2_SSH_KEY }}
          source:   "image.tar.gz"
          target:   "/tmp/deploy"

      - name: Ejecutar despliegue en servidor
        uses: appleboy/ssh-action@v1.0.3
        with:
          host:     ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key:      ${{ secrets.EC2_SSH_KEY }}
          script: |
            set -euo pipefail

            CONTAINER_NAME="${{ steps.vars.outputs.container_name }}"
            IMAGE_NAME="${{ steps.vars.outputs.image_name }}"
            INTERNAL_PORT="80"
            SUBDOMAIN="${{ steps.vars.outputs.subdomain }}"

            cd /tmp/deploy
            gunzip -c image.tar.gz | docker load
            rm -rf /tmp/deploy

            # Reusar puerto actual si el contenedor ya existe
            # | head -1 evita duplicados IPv4/IPv6 de docker port
            CURRENT_PORT=$(docker port "$CONTAINER_NAME" "$INTERNAL_PORT" 2>/dev/null | grep -oP ':\K[0-9]+' | head -1 || true)

            if [ -n "$CURRENT_PORT" ]; then
              AVAILABLE_PORT=$CURRENT_PORT
            else
              USED_PORTS=$(docker ps --format '{{.Ports}}' | grep -oP '0\.0\.0\.0:\K[0-9]+' | sort -n)
              AVAILABLE_PORT=""
              for PORT in $(seq 8080 8099); do
                if ! echo "$USED_PORTS" | grep -q "^$PORT$"; then
                  AVAILABLE_PORT=$PORT; break
                fi
              done
              [ -z "$AVAILABLE_PORT" ] && { echo "❌ Sin puertos disponibles"; exit 1; }
            fi

            docker stop "$CONTAINER_NAME" 2>/dev/null || true
            docker rm   "$CONTAINER_NAME" 2>/dev/null || true

            docker run -d \
              --name "$CONTAINER_NAME" \
              --restart unless-stopped \
              -p "$AVAILABLE_PORT:$INTERNAL_PORT" \
              "$IMAGE_NAME"

            sudo tee /etc/nginx/sites-available/"$SUBDOMAIN".conf > /dev/null <<EOF
            ... (ver Sección 4 para el bloque Nginx completo)
            EOF

            sudo ln -sf /etc/nginx/sites-available/"$SUBDOMAIN".conf \
                        /etc/nginx/sites-enabled/
            sudo nginx -t && sudo systemctl reload nginx

            sleep 5
            curl -sf http://localhost:"$AVAILABLE_PORT"/ -o /dev/null \
              && echo "✅ $CONTAINER_NAME desplegado en puerto $AVAILABLE_PORT" \
              || echo "⚠️ Health check falló"
```

---

## Sección 6 — Configurar GitHub Secrets

### Usando GitHub CLI (recomendado)

```bash
# Autenticarse (una sola vez)
gh auth login -h github.com -p https -w

# EC2
echo "<EC2_IP>"   | gh secret set EC2_HOST --repo <owner>/<repo>
echo "ubuntu"     | gh secret set EC2_USER --repo <owner>/<repo>

# SSH key (PowerShell)
Get-Content "credentials/<key>.pem" -Raw | gh secret set EC2_SSH_KEY --repo <owner>/<repo>

# SSH key (macOS/Linux)
gh secret set EC2_SSH_KEY --repo <owner>/<repo> < credentials/<key>.pem

# Cloudflare
echo "<CF_TOKEN>"   | gh secret set CLOUDFLARE_API_TOKEN --repo <owner>/<repo>
echo "<CF_ZONE_ID>" | gh secret set CLOUDFLARE_ZONE_ID   --repo <owner>/<repo>

# Verificar
gh secret list --repo <owner>/<repo>
```

Salida esperada:

```
CLOUDFLARE_API_TOKEN  Updated ...
CLOUDFLARE_ZONE_ID    Updated ...
EC2_HOST              Updated ...
EC2_SSH_KEY           Updated ...
EC2_USER              Updated ...
```

### Usando la interfaz web de GitHub

Ir a `Settings → Secrets and variables → Actions → New repository secret`.

### Comandos útiles de `gh` para monitorear el pipeline

| Comando | Descripción |
|---|---|
| `gh run list` | Ver ejecuciones recientes |
| `gh run watch` | Seguir en vivo la ejecución actual |
| `gh run view <id> --log-failed` | Ver logs de un run fallido |
| `gh run rerun <id>` | Re-ejecutar un run fallido |
| `gh workflow list` | Listar workflows del repositorio |
| `gh workflow run deploy.yml` | Disparar workflow manualmente |

---

## Sección 7 — Conexión SSH al servidor

```bash
# Conectarse
ssh -i "credentials/<key>.pem" <EC2_USER>@<EC2_HOST>

# Ejecutar comando sin entrar al servidor
ssh -i "credentials/<key>.pem" <EC2_USER>@<EC2_HOST> "comando"
```

### Diagnóstico de puertos en el servidor

```bash
# Ver puertos asignados por Docker
docker ps --format 'table {{.Names}}\t{{.Ports}}'

# Ver todos los puertos escuchando en el sistema
ss -tlnp

# Ver puertos de un contenedor específico
docker port <nombre-contenedor>

# Verificar si un puerto responde
curl -sf http://localhost:<puerto>/ && echo "OK" || echo "NO responde"

# Encontrar primer puerto libre en 8080–8099
USED=$(docker ps --format '{{.Ports}}' | grep -oP '0\.0\.0\.0:\K[0-9]+' | sort -n)
for PORT in $(seq 8080 8099); do
  if ! echo "$USED" | grep -q "^${PORT}$"; then
    echo "Primer puerto libre: $PORT"; break
  fi
done
```

---

## Sección 8 — Configurar DNS en Cloudflare

### Obtener Zone ID

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=<DOMINIO>" \
  -H "Authorization: Bearer <CF_TOKEN>" \
  -H "Content-Type: application/json" | jq '.result[0].id'
```

### Crear registros A

```bash
CF_TOKEN="<CF_TOKEN>"
ZONE_ID="<CF_ZONE_ID>"
SERVER_IP="<EC2_HOST>"

for RECORD in "@" "www" "dev"; do
  curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$RECORD\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":false}"
done
```

### Activar proxy (nube naranja) vía API

```bash
# Obtener ID del registro A para "www"
RECORD_ID=$(curl -s \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=www.<DOMINIO>" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

# Activar proxy
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"proxied":true}'
```

### Configurar SSL mode — Full (Strict) vía API

```bash
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value":"strict"}'
```

### Activar Always Use HTTPS y TLS mínimo 1.2 vía API

```bash
# Always Use HTTPS
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/always_use_https" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value":"on"}'

# Minimum TLS 1.2
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/min_tls_version" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value":"1.2"}'

# Automatic HTTPS Rewrites
curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/automatic_https_rewrites" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value":"on"}'
```

### Comandos de Cloudflare API — referencia rápida

| Acción | Endpoint |
|---|---|
| Verificar token | `GET /client/v4/user/tokens/verify` |
| Listar zonas | `GET /client/v4/zones` |
| Listar registros DNS | `GET /client/v4/zones/$ZONE_ID/dns_records` |
| Crear registro A | `POST /client/v4/zones/$ZONE_ID/dns_records` |
| Actualizar registro | `PUT /client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID` |
| Eliminar registro | `DELETE /client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID` |

---

## Sección 9 — HTTPS con Cloudflare Origin Certificate

### Arquitectura SSL

```
Usuario ──HTTPS──> Cloudflare (certificado edge) ──HTTPS──> Nginx (Origin Cert) ──HTTP──> Docker
```

- No se usa Let's Encrypt ni Certbot.
- Costo: $0 (plan gratuito de Cloudflare).
- El Origin Certificate es válido 15 años.

### Paso a paso para instalar el certificado en el servidor

**1. Generar el Origin Certificate** en Cloudflare Dashboard:
   - Ir a `kmdatasolutions.com` → **SSL/TLS** → **Origin Server** → **Create Certificate**
   - Tipo: RSA 2048 | Hostnames: `*.kmdatasolutions.com`, `kmdatasolutions.com` | Vigencia: 15 años
   - Guardar el certificado como `origin.pem` y la llave privada como `origin-key.pem`
   - **La llave privada solo se muestra una vez.**

**2. Conectarse al servidor por SSH** (ver Sección 7).

**3. Crear directorio y copiar archivos:**

```bash
sudo mkdir -p /etc/ssl/cloudflare

# Pegar el contenido del Origin Certificate
sudo nano /etc/ssl/cloudflare/origin.pem

# Pegar el contenido de la Private Key
sudo nano /etc/ssl/cloudflare/origin-key.pem

# Permisos correctos
sudo chmod 644 /etc/ssl/cloudflare/origin.pem
sudo chmod 600 /etc/ssl/cloudflare/origin-key.pem
sudo chown root:root /etc/ssl/cloudflare/*
```

**4. Abrir puerto 443 en el Security Group de AWS:**
   - AWS Console → EC2 → Instancia → Security Group → Edit inbound rules
   - Agregar regla HTTPS (TCP 443) para `0.0.0.0/0` y `::/0`

**5. Configurar Nginx con HTTPS** (ya generado por `deploy.sh` — ver Sección 4).

**6. Validar y recargar Nginx:**

```bash
sudo nginx -t && sudo systemctl reload nginx

# Verificar que escucha en 443
ss -tlnp | grep ':443'

# Probar localmente
curl -sf -k https://localhost:443/ -o /dev/null && echo "HTTPS OK" || echo "HTTPS falló"
```

**7. Activar proxy (nube naranja) en Cloudflare** para cada registro DNS (ver Sección 8).

**8. Configurar SSL Mode → Full (Strict)** (ver Sección 8).

### Verificación final desde la terminal local

```bash
# HTTPS producción
curl -I https://kmdatasolutions.com

# HTTPS desarrollo
curl -I https://dev.kmdatasolutions.com

# Redirect HTTP → HTTPS
curl -I http://kmdatasolutions.com

# Verificar certificado (el issuer debe contener "Cloudflare")
echo | openssl s_client -connect kmdatasolutions.com:443 \
  -servername kmdatasolutions.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

### Tabla de errores comunes

| Error | Causa | Solución |
|---|---|---|
| **526** Invalid SSL certificate | `origin.pem` mal copiado o vacío | Volver al paso 3 y pegar el certificado completo |
| **525** SSL handshake failed | Nginx no escucha en 443, o `origin-key.pem` corrupto | Verificar `ss -tlnp \| grep 443`, repetir paso 3 |
| **521** Web server is down | Nginx no está corriendo | `sudo systemctl start nginx` |
| **ERR_TOO_MANY_REDIRECTS** | SSL mode en "Flexible" — loop de redirects | Cambiar SSL mode a **Full (Strict)** |
| Mixed content warnings | Assets cargando por HTTP | Activar Automatic HTTPS Rewrites |

---

## Sección 10 — Configurar Nginx manualmente (sin pipeline)

### Crear config HTTP básica para un subdominio

```bash
sudo tee /etc/nginx/sites-available/<subdominio>.conf > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name <subdominio>;

    location / {
        proxy_pass         http://localhost:<puerto>;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/<subdominio>.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Sección 11 — Desplegar un nuevo proyecto

Para agregar un proyecto completamente nuevo al mismo servidor:

1. Crear repositorio con `Dockerfile` propio.
2. Copiar `.github/workflows/deploy.yml` y ajustar las variables:
   - `container_name` → nombre único del contenedor
   - `subdomain` → subdominio del nuevo proyecto
   - `image_name` → nombre de la imagen Docker
3. Agregar los mismos GitHub Secrets (`EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`).
4. Crear registro DNS en Cloudflare apuntando al mismo servidor.
5. `deploy.sh` asignará automáticamente el primer puerto libre en 8080–8099.

---

## Sección 12 — Consideraciones de seguridad

- **Nunca** subir archivos `.pem` al repositorio. Usar GitHub Secrets.
- **Nunca** subir tokens de Cloudflare al repositorio. Usar GitHub Secrets.
- **Nunca** subir el Origin Certificate ni la Private Key al repositorio.
- Verificar que `.gitignore` incluya `credentials/` y `*.pem`.
- Los puertos internos (8080–8099) **no deben** estar abiertos en el Security Group de AWS. Nginx hace el proxy desde los puertos 80/443.
- El Security Group debe tener abiertos: **22** (SSH), **80** (HTTP), **443** (HTTPS).
- El API Token de Cloudflare debe tener **permisos mínimos**: solo Zone → DNS → Edit en las zonas necesarias.
- El Origin Certificate solo funciona con el proxy de Cloudflare activo (nube naranja). Si alguien accede directamente a la IP, verá un certificado no confiable — este comportamiento es esperado y correcto.
- MongoDB corre en el puerto 27017 de acceso **solo local** — no abrir en Security Group.

---

## Sección 13 — Mejoras futuras catalogadas

| Mejora | Prioridad |
|---|---|
| Usar GitHub Container Registry (ghcr.io) en vez de SCP | Alta |
| Agregar `HEALTHCHECK` en el Dockerfile | Media |
| Rollback automático si health check falla | Media |
| Notificaciones a Slack/Discord en cada deploy | Baja |
| Migrar de `docker run` a `docker-compose.yml` | Media |
| `docker image prune` periódico para liberar espacio | Baja |
| Step en workflow que cree/actualice DNS via Cloudflare API | Media |
| HSTS preload list | Baja |
