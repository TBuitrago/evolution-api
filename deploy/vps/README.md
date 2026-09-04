# Despliegue de Evolution API en el VPS (WhatsApp por QR)

Guía específica para el servidor `srv1773432`, que ya corre Traefik + n8n + Postgres.
Objetivo: exponer Evolution API en `https://evo.tbadigitals.com`, conectar **un**
número de WhatsApp por QR code (Baileys) y dejarlo hablando con n8n.

## Cómo queda montado

```
Internet :80/:443
      │
      ▼
 n8n-traefik-1  (Traefik v3.7.5, certresolver "mytlschallenge")
      ├── n8n.tbadigitals.com  ──► n8n-n8n-1:5678        (ya existía)
      └── evo.tbadigitals.com  ──► evolution_api:8080    (nuevo)
                                        │
              red n8n_default ──────────┼──► postgres-bots:5432/evolution
              red internal    ──────────┴──► evolution_redis:6379
```

Decisiones y por qué:

| Decisión | Razón |
|---|---|
| Reusar el Traefik existente | Los puertos 80/443 ya están tomados. Meter otro proxy rompe n8n. |
| No publicar el puerto 8080 al host | Todo entra por Traefik con TLS. La API nunca queda en HTTP plano. |
| Reusar `postgres-bots` con base y rol propios | 1 vCPU: un segundo motor Postgres no se justifica. Aislamiento lógico por base. |
| Redis propio en red privada | Baileys reconecta mucho mejor con cache. Cuesta ~15 MB. |
| Manager integrado (`/manager`), sin contenedor extra | Evolution v2 ya sirve el manager en la propia API. |
| `CACHE_REDIS_SAVE_INSTANCES=false` | La sesión de WhatsApp queda en Postgres, no en Redis. Si Redis se pierde, no hay que re-escanear el QR. |
| `DATABASE_SAVE_DATA_HISTORIC=false` | La sincronización del historial completo satura 1 vCPU y llena la base. |
| Imagen pineada en `v2.3.7` | `latest` puede cambiar de versión mayor en un `docker compose pull` y romper la base. |

> **No usar el `docker-compose.yaml` de la raíz del repo.** Ese exige la red externa
> `dokploy-network` (que no existe en este VPS), publica el manager en el puerto 3000
> sin TLS, y levanta su propio Postgres y Redis duplicando lo que ya hay.

---

## Paso 0 — DNS (bloqueante)

`evo.tbadigitals.com` **no resuelve todavía**. Hasta que resuelva, Traefik no puede
emitir el certificado y todo lo demás falla.

En el DNS de `tbadigitals.com` (donde ya está el registro de `n8n`), crear:

```
Tipo: A      Nombre: evo      Valor: 2.24.199.234      TTL: 300      Proxy: DESACTIVADO
```

Si el DNS está en Cloudflare, la nube tiene que quedar **gris**, no naranja: el
certresolver `mytlschallenge` usa el desafío TLS-ALPN-01, que necesita llegar al
puerto 443 del servidor sin intermediarios. Con el proxy naranja, la emisión falla.

Verificar antes de seguir:

```bash
getent hosts evo.tbadigitals.com     # debe devolver 2.24.199.234
```

---

## Paso 1 — Copiar los archivos al VPS

Siguiendo la convención que ya usa el servidor (`/docker/n8n`):

```bash
mkdir -p /docker/evolution && cd /docker/evolution
```

Bajar `docker-compose.yml` y `.env.example` directamente desde el repo:

```bash
BASE=https://raw.githubusercontent.com/TBuitrago/evolution-api/claude/whatsapp-qr-vps-setup-oo490g/deploy/vps
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/.env.example"       -o .env.example
curl -fsSL "$BASE/README.md"          -o README.md
```

(Si el repo pasa a ser privado, subirlos con `scp` desde una máquina con acceso.)

---

## Paso 2 — Crear la base y el rol en `postgres-bots`

El superusuario de ese contenedor es `n8nbots` (no existe el rol `postgres`).

```bash
# Generar y GUARDAR esta contraseña, se usa en el paso 3
DB_PASS=$(openssl rand -hex 24); echo "PASSWORD DE LA BASE: $DB_PASS"

docker exec -i postgres-bots psql -U n8nbots -d bots <<SQL
CREATE ROLE evolution LOGIN PASSWORD '$DB_PASS';
CREATE DATABASE evolution OWNER evolution;
SQL

# Verificar
docker exec -i postgres-bots psql -U n8nbots -d bots -c "\l" | grep evolution
```

Las migraciones de Prisma corren solas al arrancar el contenedor (están en el
`ENTRYPOINT` de la imagen). No hay que ejecutar nada a mano.

---

## Paso 3 — Configurar el `.env`

```bash
cd /docker/evolution
cp .env.example .env

API_KEY=$(openssl rand -hex 32); echo "API KEY: $API_KEY"

sed -i "s|^AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$API_KEY|" .env
sed -i "s|^DATABASE_CONNECTION_URI=.*|DATABASE_CONNECTION_URI=postgresql://evolution:$DB_PASS@postgres-bots:5432/evolution?schema=public|" .env

chmod 600 .env

# Verificar que no quedaron placeholders (ignorando comentarios)
grep -n "^[^#].*<<<" .env && echo "FALTA REEMPLAZAR lo de arriba" || echo "OK: .env completo"

# Ver los valores criticos con la password enmascarada
grep -E "^(SERVER_URL|DATABASE_CONNECTION_URI|CACHE_REDIS_URI)=" .env \
  | sed -E 's|(://[^:]+:)[^@]+@|\1***@|'
```

Guardá `API_KEY` y `DB_PASS` en tu gestor de contraseñas. La API key es la llave
maestra: quien la tenga controla el WhatsApp conectado.

---

## Paso 4 — Levantar

```bash
cd /docker/evolution
docker compose up -d
docker compose logs -f api
```

En los logs se debe ver `Migration succeeded`, luego `Prisma generate succeeded`
y finalmente el banner de Evolution API escuchando en el 8080.

El primer arranque tarda: descarga ~400 MB de imagen y corre todas las migraciones.
En 1 vCPU pueden ser varios minutos. Traefik detecta el contenedor solo (lee el
socket de Docker) y pide el certificado en cuanto el DNS resuelve.

---

## Paso 5 — Verificar

```bash
# 1. El contenedor está arriba
docker compose ps

# 2. Responde por dentro de la red
docker exec n8n-traefik-1 wget -qO- http://evolution_api:8080/ | head -c 300

# 3. Responde por fuera, con TLS válido
curl -I https://evo.tbadigitals.com
curl -s https://evo.tbadigitals.com | head -c 300

# 4. La API key funciona
curl -s https://evo.tbadigitals.com/instance/fetchInstances \
  -H "apikey: TU_API_KEY"
```

Si el paso 3 da error de certificado, revisar el DNS (paso 0) y luego:

```bash
docker logs n8n-traefik-1 --tail 100 | grep -i -E "acme|certificate|error"
```

---

## Paso 6 — Conectar el WhatsApp por QR

**Opción A — manager web (recomendada).** Abrir `https://evo.tbadigitals.com/manager`,
entrar con la API key, crear la instancia y escanear el QR con el celular en
*WhatsApp → Dispositivos vinculados → Vincular dispositivo*.

**Opción B — por API:**

```bash
# Crear la instancia
curl -s -X POST https://evo.tbadigitals.com/instance/create \
  -H "apikey: TU_API_KEY" -H "Content-Type: application/json" \
  -d '{"instanceName":"tba","integration":"WHATSAPP-BAILEYS","qrcode":true}'

# Si el QR expira, pedir uno nuevo
curl -s https://evo.tbadigitals.com/instance/connect/tba -H "apikey: TU_API_KEY"

# Confirmar el estado (debe quedar en "open")
curl -s https://evo.tbadigitals.com/instance/connectionState/tba -H "apikey: TU_API_KEY"
```

El QR vence en ~40 segundos y se regenera hasta `QRCODE_LIMIT=30` veces.

---

## Paso 7 — Conectar con n8n

Ambos contenedores están en la red `n8n_default`, así que se hablan por nombre
interno sin salir a internet.

**Evolution → n8n** (mensajes entrantes). Crear un nodo *Webhook* en n8n, copiar
su path, y registrarlo en la instancia con la **URL interna**:

```bash
curl -s -X POST https://evo.tbadigitals.com/webhook/set/tba \
  -H "apikey: TU_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "webhook": {
      "enabled": true,
      "url": "http://n8n:5678/webhook/EL-PATH-DE-TU-WEBHOOK",
      "webhookByEvents": false,
      "events": ["MESSAGES_UPSERT", "CONNECTION_UPDATE"]
    }
  }'
```

**n8n → Evolution** (mensajes salientes). Nodo *HTTP Request*:

- Método: `POST`
- URL: `http://evolution_api:8080/message/sendText/tba`
- Header: `apikey: TU_API_KEY` (guardarla como credencial de n8n, no en texto plano)
- Body JSON: `{"number": "573001112233", "text": "hola"}`

---

## Operación

```bash
cd /docker/evolution

docker compose logs -f api          # logs
docker compose restart api          # reiniciar
docker compose down                 # bajar (NO borra volúmenes)
docker compose pull && docker compose up -d   # actualizar (ver aviso abajo)
docker stats --no-stream            # consumo de recursos
```

**Backup.** Lo crítico es la base `evolution`: ahí viven la sesión de WhatsApp y
los mensajes. Sin ella hay que re-escanear el QR.

```bash
docker exec postgres-bots pg_dump -U evolution -d evolution \
  | gzip > /root/backups/evolution-$(date +%F).sql.gz
```

**Actualizar de versión.** La imagen está pineada en `v2.3.7`. Para subir de versión,
editar el tag en `docker-compose.yml`, **hacer el backup primero**, y luego
`docker compose up -d`. Las migraciones corren solas y no son reversibles.

---

## Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `network n8n_default declared as external, but could not be found` | El stack de n8n está caído | `cd /docker/n8n && docker compose up -d` |
| 404 de Traefik en el dominio | El router no cargó | `docker logs n8n-traefik-1 \| grep -i evolution`; verificar que el label `traefik.enable=true` está y que el contenedor está en `n8n_default` |
| Certificado inválido / `TRAEFIK DEFAULT CERT` | DNS mal o proxy de Cloudflare activo | Paso 0. El desafío TLS-ALPN-01 necesita el 443 directo |
| `Migration failed` en el arranque | Rol o base mal creados | Repetir el paso 2 y revisar el `DATABASE_CONNECTION_URI` |
| El QR no aparece en el manager | WebSocket bloqueado o `SERVER_URL` mal | Confirmar `SERVER_URL=https://evo.tbadigitals.com` y `WEBSOCKET_ENABLED=true` |
| Se desconecta solo cada rato | Sesión invalidada por WhatsApp | Revisar `docker compose logs api \| grep -i "connection"`; puede requerir re-vincular |
| Contenedor reiniciando sin parar | OOM en 1 vCPU / 3.8 GB | `docker stats`; revisar que `DATABASE_SAVE_DATA_HISTORIC=false` |

---

## Notas de seguridad

- `ufw` está inactivo. Solo 22, 80 y 443 quedan expuestos (Docker publica directo,
  saltándose ufw de todos modos). Si se activa el firewall, hay que tenerlo en cuenta.
- Traefik corre con `--api.insecure=true`: su dashboard queda accesible desde dentro
  de la red `n8n_default`, sin autenticación. No está publicado a internet, pero
  vale la pena apagarlo o protegerlo cuando se pueda.
- El `.env` debe quedar en `chmod 600`. Contiene la API key y la contraseña de la base.
- Conectar WhatsApp por QR usa Baileys, un cliente **no oficial**. El número puede ser
  baneado si se usa para envío masivo o mensajes en frío. Para responder conversaciones
  existentes el riesgo es bajo.
