# Evolution API ↔ n8n — guía de integración

Documento de traspaso para quien construya la automatización en n8n.
Describe la instalación que ya está corriendo en producción, el contrato de datos
exacto y las reglas que no se pueden saltar.

Todas las referencias `archivo:línea` apuntan al código de Evolution API v2.3.7,
que es la versión desplegada.

---

## 1. Qué hay montado

```
Internet :443
      │
      ▼
  Traefik  ──► evo.tbadigitals.com ──► evolution_api:8080
      └─────► n8n.tbadigitals.com  ──► n8n:5678
                                          │
        red Docker "n8n_default" ─────────┤
                                          ├──► postgres-bots:5432/evolution
                                          └──► evolution_redis:6379 (red privada)
```

| Dato | Valor |
|---|---|
| URL pública | `https://evo.tbadigitals.com` |
| **URL interna (la que debe usar n8n)** | `http://evolution_api:8080` |
| Manager (UI de administración) | `https://evo.tbadigitals.com/manager` |
| Nombre de la instancia | `tba` |
| ID de la instancia | `5d3a0c37-fde9-4897-a394-07d2d33ac9e6` |
| Canal | Baileys (WhatsApp Web vía QR) — **no** es la API oficial de Meta |
| Versión | Evolution API v2.3.7 |
| Servidor | 1 vCPU, 3.8 GB RAM |

**Usar siempre la URL interna desde n8n.** Ambos contenedores están en la misma red
Docker, así que `http://evolution_api:8080` no sale a internet, no pasa por Traefik
y no consume TLS. La URL pública es solo para el manager y para depurar desde fuera.

### Credenciales

La API key global está en el servidor, en `/docker/evolution/.env`, variable
`AUTHENTICATION_API_KEY`. **No se incluye en este documento.** Pedirla al
administrador del VPS.

En n8n debe guardarse como **credencial** (tipo *Header Auth*, nombre `apikey`),
nunca escrita a mano dentro de un nodo: los nodos se exportan con el workflow.

Toda petición a Evolution lleva la cabecera:

```
apikey: <la llave>
```

---

## 2. Cómo llega un mensaje

### Webhook configurado

| Campo | Valor |
|---|---|
| URL destino | `http://n8n:5678/webhook/<id-del-webhook>` |
| Método | **POST** (el nodo Webhook de n8n viene en GET por defecto — hay que cambiarlo) |
| Eventos | `MESSAGES_UPSERT`, `CONNECTION_UPDATE` |
| `webhookByEvents` | `false` |
| `base64` | `false` |

> `webhookByEvents: true` hace que Evolution le pegue el nombre del evento al final
> de la URL (`.../messages-upsert`), y entonces n8n devuelve 404. Debe quedar en
> `false`. Al escribirlo por API la propiedad se llama **`byEvents`**, no
> `webhookByEvents` (`webhook.schema.ts`); el nombre largo es solo como se lee.

> El workflow de n8n tiene que estar **activo** para que la ruta `/webhook/<id>`
> exista. La ruta `/webhook-test/<id>` solo vive mientras el editor está escuchando.

### Estructura del envío

Evolution arma el cuerpo así (`webhook.controller.ts:93-103`):

```json
{
  "event": "messages.upsert",
  "instance": "tba",
  "data": { },
  "destination": "http://n8n:5678/webhook/...",
  "date_time": "2026-09-04T08:05:40.000Z",
  "sender": "573001234567@s.whatsapp.net",
  "server_url": "https://evo.tbadigitals.com",
  "apikey": "..."
}
```

> ⚠️ **El payload incluye la API key en texto plano.** No reenviar el objeto
> completo a servicios de terceros (LLMs, logs externos, Sheets, Slack) sin quitar
> antes ese campo. Extraer solo lo que se necesita.

Según cómo esté configurado el nodo Webhook de n8n, esto llega en `$json.body` o
directamente en `$json`. Verificarlo con el primer payload real y ajustar las
expresiones.

### El objeto `data` de `MESSAGES_UPSERT`

Construido en `prepareMessage()` (`whatsapp.baileys.service.ts:4652-4682`):

| Campo | Contenido |
|---|---|
| `key.remoteJid` | Quién escribe. **Es el valor que se usa como `number` al responder.** |
| `key.fromMe` | `true` si el mensaje lo enviamos nosotros. **Filtro obligatorio, ver §3.** |
| `key.id` | ID del mensaje. Necesario para reaccionar, citar o marcar como leído. |
| `key.participant` | En grupos, quién escribió dentro del grupo. |
| `pushName` | Nombre que el contacto tiene puesto en WhatsApp. No es confiable como identidad. |
| `message` | El contenido. La forma depende del tipo, ver abajo. |
| `messageType` | `conversation`, `imageMessage`, `audioMessage`, `documentMessage`, `videoMessage`, `stickerMessage`, `locationMessage`, `contactMessage`, … |
| `messageTimestamp` | Unix en **segundos**, no milisegundos. |
| `contextInfo` | Presente cuando el mensaje cita a otro. |
| `source` | Dispositivo de origen: `android`, `ios`, `web`, `desktop`. |
| `instanceId` | UUID de la instancia. |

### Dónde está el texto

**Detalle que ahorra mucho tiempo:** Evolution normaliza los mensajes de texto.
En `prepareMessage()` líneas 4678-4682:

```js
if (messageRaw.message.extendedTextMessage) {
  messageRaw.messageType = 'conversation';
  messageRaw.message.conversation = messageRaw.message.extendedTextMessage.text;
  delete messageRaw.message.extendedTextMessage;
}
```

Es decir: un texto simple, uno con vista previa de enlace y uno que responde a otro
mensaje **llegan todos igual**, con `messageType: "conversation"` y el texto en:

```
data.message.conversation
```

No hace falta manejar `extendedTextMessage` por separado.

Para los demás tipos:

| Tipo | Dónde está lo útil |
|---|---|
| Texto | `data.message.conversation` |
| Imagen | `data.message.imageMessage.caption` (el pie, puede venir vacío) |
| Video | `data.message.videoMessage.caption` |
| Documento | `data.message.documentMessage.fileName` |
| Audio / nota de voz | `data.message.audioMessage` (metadatos; no trae el audio) |
| Ubicación | `data.message.locationMessage.degreesLatitude` / `.degreesLongitude` |
| Contacto | `data.message.contactMessage.vcard` |

### Media

`base64` está en `false` a propósito: en 1 vCPU, inflar cada audio o imagen dentro
del payload es caro. El webhook trae los **metadatos** de la media, no el archivo.

Para obtener el binario hay que pedirlo:

```
POST http://evolution_api:8080/chat/getBase64FromMediaMessage/tba
{
  "message": { "key": { "id": "<key.id>", "remoteJid": "<key.remoteJid>", "fromMe": false } },
  "convertToMp4": false
}
```

Si el volumen de media crece, la alternativa correcta es activar S3/MinIO, no
subir `base64` a `true`.

---

## 3. Reglas que no se pueden saltar

### 3.1 Filtrar `fromMe` — obligatorio

`MESSAGES_UPSERT` **también dispara con los mensajes que enviamos nosotros**. Si el
flujo responde sin filtrar, el bot contesta su propia respuesta y se dispara en
bucle hasta que WhatsApp bloquea el número.

**Primer nodo después del Webhook, siempre**, un *IF* o *Filter*:

```
{{ $json.body.data.key.fromMe }}   →   Boolean   →   is false
```

Es la causa número uno de números baneados en Evolution.

### 3.2 Ignorar mensajes que no son conversación

Descartar antes de procesar:

- `key.remoteJid === "status@broadcast"` → son los estados/historias, no son chats.
- `key.remoteJid` que termine en `@g.us` → grupos, si no están en alcance.
- `messageType` que no se sepa manejar → responder algo genérico o no responder,
  pero nunca reventar el flujo.

### 3.3 Idempotencia

Evolution reintenta el webhook hasta **10 veces** con backoff exponencial si n8n no
responde 2xx (`WEBHOOK_RETRY_MAX_ATTEMPTS=10`). Si el workflow tarda o falla a la
mitad, el mismo mensaje puede llegar varias veces.

Dos consecuencias prácticas:

1. **Responder 200 rápido.** Si el flujo hace algo lento (llamar un LLM, consultar
   una base), conviene que el nodo Webhook responda de inmediato
   (*Respond: Immediately*) y el trabajo pesado siga por detrás.
2. **Deduplicar por `data.key.id`**, que es único por mensaje, antes de enviar
   cualquier respuesta.

### 3.4 Ritmo de envío

No hay límite de velocidad dentro de Evolution: si el flujo dispara 200 mensajes en
un bucle, los manda todos. WhatsApp lo lee como comportamiento automatizado.

- Usar el parámetro `delay` (milisegundos) en cada envío.
- Espaciar los envíos masivos. Nunca enviar en frío a números que no escribieron primero.
- Variar el texto: mensajes idénticos repetidos es lo que más rápido dispara reportes.

---

## 4. Cómo responder

Nodo *HTTP Request* en n8n. Método `POST`, cabecera `apikey` desde la credencial.

### Texto

```
POST http://evolution_api:8080/message/sendText/tba
```

```json
{
  "number": "{{ $json.body.data.key.remoteJid }}",
  "text": "Hola, ¿en qué te ayudo?",
  "delay": 1200
}
```

Campos obligatorios: `number` y `text` (`message.schema.ts:92`). Opcionales útiles:

| Campo | Para qué |
|---|---|
| `delay` | Milisegundos de espera antes de enviar. Hace que se vea humano. |
| `linkPreview` | `false` para no generar vista previa de enlaces. |
| `quoted` | Citar un mensaje: `{ "key": { ... }, "message": { ... } }` |
| `mentioned` | Array de números a mencionar, en grupos. |

Se puede pasar el `remoteJid` completo (`573001234567@s.whatsapp.net`) o solo el
número; Evolution lo normaliza con `createJid()`.

### Otros envíos disponibles

Todos bajo `POST http://evolution_api:8080/message/<ruta>/tba`
(`sendMessage.router.ts:44-175`):

| Ruta | Uso |
|---|---|
| `sendText` | Texto |
| `sendMedia` | Imagen, video, documento — campo `media` con URL o base64, más `mediatype` |
| `sendWhatsAppAudio` | Nota de voz — campo `audio` |
| `sendSticker` | Sticker |
| `sendLocation` | `latitude`, `longitude`, `name`, `address` |
| `sendContact` | Tarjeta de contacto |
| `sendReaction` | Emoji sobre un mensaje — requiere `key` |
| `sendPoll` | Encuesta — `name`, `values[]`, `selectableCount` |
| `sendList` | Lista con secciones |
| `sendButtons` | Botones (`reply`, `url`, `call`, `copy`) |
| `sendPtv` | Video circular |
| `sendStatus` | Publicar un estado |

> Los botones y listas tienen soporte irregular en WhatsApp según la versión del
> cliente que tenga el destinatario. Probar en un teléfono real antes de
> comprometerlos en un flujo; si no se ven, caer a texto con opciones numeradas.

### Acciones de chat

Bajo `POST http://evolution_api:8080/chat/<ruta>/tba` (`chat.router.ts`):

| Ruta | Uso |
|---|---|
| `sendPresence` | Mostrar "escribiendo…" — `{ "number": "...", "presence": "composing", "delay": 2000 }` |
| `markMessageAsRead` | Marcar leído — `{ "readMessages": [ { "id": "...", "remoteJid": "...", "fromMe": false } ] }` |
| `whatsappNumbers` | Verificar si un número existe en WhatsApp — `{ "numbers": ["573001234567"] }` |
| `fetchProfilePictureUrl` | Foto de perfil de un contacto |
| `findMessages` | Consultar el historial guardado en la base |
| `updateMessage` | Editar un mensaje ya enviado |
| `deleteMessageForEveryone` | Eliminar para todos (método `DELETE`) |

Un patrón que se siente natural: `sendPresence` con `composing` → esperar →
`sendText`. Evita que las respuestas aparezcan instantáneas.

---

## 5. Formato de números

**Colombia: `57` + los 10 dígitos del celular.** Sin `+`, sin espacios, sin guiones.

```
573001234567     ✅
+57 300 123 4567 ❌
3001234567       ❌ (falta el indicativo)
```

`createJid()` (`src/utils/createJid.ts`) tiene normalizaciones especiales **solo**
para México (52), Argentina (54) y Brasil (55). Colombia pasa sin transformar, así
que el formato debe venir correcto desde el flujo.

### Tipos de JID que se van a ver

| Sufijo | Qué es |
|---|---|
| `@s.whatsapp.net` | Chat individual. El caso normal. |
| `@g.us` | Grupo. |
| `@lid` | Identificador nuevo de WhatsApp, sin número visible. Puede aparecer; el campo `key.remoteJidAlt` suele traer el número real. |
| `status@broadcast` | Estados/historias. **Descartar siempre.** |

---

## 6. Límites y estado actual del sistema

### Del servidor

- **1 vCPU y 3.8 GB de RAM**, compartidos con n8n, Traefik y dos Postgres. No es una
  máquina para procesamiento pesado. Si el flujo llama a un LLM, que la llamada la
  haga n8n hacia afuera, no algo montado en este servidor.
- Sin S3: la media vive en disco local. 38 GB libres al momento del despliegue.

### De la instalación

| Cosa | Estado | Implicación |
|---|---|---|
| Historial de mensajes | **Desactivado** (`DATABASE_SAVE_DATA_HISTORIC=false`) | La tabla `Chat` está vacía y la vista de chats del manager no muestra nada. Los **mensajes nuevos sí se guardan**. Es una decisión consciente por el vCPU único. |
| Grupos | Revisar `groupsIgnore` en los ajustes de la instancia | Si está en `true`, los mensajes de grupo no llegan al webhook (`whatsapp.baileys.service.ts:1174`). |
| `syncFullHistory` | `false` | No se importa el historial al vincular. |
| Media en base64 | `false` | Ver §2. |
| Números conectados | **Uno solo** | No hay multi-número. Añadir otro requiere otra instancia y evaluar si el servidor aguanta. |

### Riesgo de bloqueo

Esto es Baileys, un cliente **no oficial** de WhatsApp Web. El número puede ser
bloqueado por WhatsApp. Reduce el riesgo:

- Responder solo a quien escribió primero.
- Nunca enviar campañas masivas ni mensajes en frío desde este número.
- Espaciar y variar los mensajes.
- No dejar `alwaysOnline` activo.

Si el número se bloquea, se pierde el canal. Vale la pena que sea un número
dedicado, no el personal de nadie.

---

## 7. Comprobaciones rápidas

Desde el VPS, en `/docker/evolution`:

```bash
KEY=$(grep '^AUTHENTICATION_API_KEY=' .env | cut -d= -f2)

# ¿El número sigue conectado? Debe decir "open"
curl -s https://evo.tbadigitals.com/instance/connectionState/tba -H "apikey: $KEY"; echo

# ¿Cómo está configurado el webhook?
curl -s https://evo.tbadigitals.com/webhook/find/tba -H "apikey: $KEY" | python3 -m json.tool

# Ajustes de la instancia
curl -s https://evo.tbadigitals.com/settings/find/tba -H "apikey: $KEY" | python3 -m json.tool

# Ver los webhooks salir en vivo (requiere WEBHOOKS en LOG_LEVEL)
docker compose logs -f api | grep -i -E "webhook|sendData"
```

Para depurar webhooks hay que encender el log, que está apagado en producción
(`webhook.controller.ts:90` exige `WEBHOOKS` dentro de `LOG_LEVEL`):

```bash
sed -i 's|^LOG_LEVEL=.*|LOG_LEVEL=ERROR,WARN,INFO,LOG,WEBHOOKS|' .env
docker compose up -d --force-recreate api
```

> Un cambio en `.env` **no** se aplica con `docker compose restart`: las variables
> quedan fijadas al crear el contenedor. Hay que usar `up -d --force-recreate`.

Acordarse de volver a `LOG_LEVEL=ERROR,WARN,INFO,LOG` al terminar.

---

## 8. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| El webhook no dispara nunca | `MESSAGES_UPSERT` no está en la lista de eventos | Revisar con `webhook/find`; el filtro es exacto y en MAYÚSCULAS (`webhook.controller.ts:106`) |
| n8n devuelve 404 y Evolution reintenta | El workflow no está activo, o `byEvents` está en `true` | Activar el workflow; poner `byEvents: false` |
| Llega el evento pero el nodo no arranca | El nodo Webhook está en GET | Cambiarlo a POST |
| El bot se responde a sí mismo | Falta el filtro `fromMe` | §3.1 |
| El mismo mensaje se procesa varias veces | Reintentos por respuesta lenta | §3.3 |
| `state: "close"` | La sesión se cayó | Re-vincular por QR desde el manager |
| El manager no muestra chats | `DATABASE_SAVE_DATA_HISTORIC=false` | Es esperado, ver §6 |

---

## 9. Decisiones pendientes

Cosas que quedaron sin definir y que el flujo va a tener que resolver:

1. **Qué hacer con audios.** Hoy llegan solo como metadatos. Si se quiere
   transcribirlos, hay que llamar `getBase64FromMediaMessage` y mandar el binario a
   un servicio de transcripción — con el costo de CPU y de red que eso implica.
2. **Grupos: dentro o fuera.** Definirlo y dejar `groupsIgnore` acorde.
3. **Handoff a humano.** No hay ninguna lógica de "el bot se calla y contesta una
   persona". Si se necesita, hay que construirla en n8n (una bandera por
   `remoteJid` con estado en la base de n8n o en Redis).
4. **Horario de atención.** No hay nada configurado. Si el bot no debe responder de
   madrugada, es lógica de n8n.
5. **Qué se guarda y dónde.** Evolution guarda los mensajes en su Postgres, pero no
   es un CRM. Si se necesita historial consultable por el negocio, hay que
   persistirlo desde n8n a donde corresponda.
