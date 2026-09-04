-- ============================================================================
-- Control de pausa del chatbot por contacto
--
-- Se instala en la base "bots" del contenedor postgres-bots, NO en la base
-- "evolution": esa segunda es propiedad de las migraciones de Prisma y una
-- actualizacion de Evolution API podria chocar con tablas ajenas.
--
-- Aplicar con:
--   docker exec -i postgres-bots psql -U n8nbots -d bots < bot-estado.sql
--
-- Es idempotente: se puede correr varias veces sin romper nada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Estado del bot por contacto
--
-- La ausencia de fila significa "bot activo". Solo se guardan las excepciones.
--
--   pausado    -> escalado a un humano. Temporal si "hasta" tiene fecha.
--   no_viable  -> descartado. Permanente ("hasta" en NULL).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bot_estado (
  remote_jid   text        PRIMARY KEY,
  estado       text        NOT NULL CHECK (estado IN ('pausado', 'no_viable')),
  motivo       text,
  pausado_por  text,
  hasta        timestamptz,
  actualizado  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  bot_estado             IS 'Contactos donde el chatbot NO debe responder. Sin fila = bot activo.';
COMMENT ON COLUMN bot_estado.remote_jid  IS 'key.remoteJid tal como llega en el webhook, con sufijo (@s.whatsapp.net / @lid).';
COMMENT ON COLUMN bot_estado.motivo      IS 'Texto libre. Por que se pauso o se descarto.';
COMMENT ON COLUMN bot_estado.pausado_por IS 'Quien lo pauso: "asesor", "flujo", el nombre de una persona.';
COMMENT ON COLUMN bot_estado.hasta       IS 'Vencimiento de la pausa. NULL = indefinida. El bot retoma solo al vencer.';

-- Para el barrido de pausas vencidas y para reportes.
CREATE INDEX IF NOT EXISTS bot_estado_hasta_idx  ON bot_estado (hasta) WHERE hasta IS NOT NULL;
CREATE INDEX IF NOT EXISTS bot_estado_estado_idx ON bot_estado (estado);

-- ----------------------------------------------------------------------------
-- 2. Mensajes que envio el bot
--
-- Necesaria para distinguir un "fromMe: true" del bot de uno escrito a mano
-- por el asesor: los dos llegan como MESSAGES_UPSERT y son indistinguibles
-- por el evento (whatsapp.baileys.service.ts:1165 procesa 'notify' y 'append')
-- y por el campo "source" (la API y WhatsApp Web salen los dos como 'web').
--
-- Es de vida corta: solo importa durante los segundos siguientes al envio.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bot_enviado (
  key_id      text        PRIMARY KEY,
  remote_jid  text        NOT NULL,
  enviado_en  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  bot_enviado            IS 'key.id de los mensajes enviados por el bot. Se purga sola, ver bot_enviado_purgar().';
COMMENT ON COLUMN bot_enviado.key_id     IS 'El key.id que devuelve /message/sendText al enviar.';

CREATE INDEX IF NOT EXISTS bot_enviado_enviado_en_idx ON bot_enviado (enviado_en);

-- ----------------------------------------------------------------------------
-- 3. Purga
--
-- bot_enviado solo sirve para la ventana inmediata al envio. Esta funcion la
-- llama el propio INSERT desde n8n, asi no hace falta un cron.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bot_enviado_purgar() RETURNS void AS $$
  DELETE FROM bot_enviado WHERE enviado_en < now() - interval '2 hours';
$$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 4. Vista de consulta para el equipo comercial
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_bot_estado AS
SELECT
  remote_jid,
  replace(replace(remote_jid, '@s.whatsapp.net', ''), '@lid', '') AS numero,
  estado,
  motivo,
  pausado_por,
  hasta,
  CASE
    WHEN estado = 'no_viable'                 THEN 'descartado'
    WHEN hasta IS NULL                        THEN 'pausado indefinido'
    WHEN hasta > now()                         THEN 'pausado hasta ' || to_char(hasta, 'DD/MM HH24:MI')
    ELSE                                            'vencido, bot activo'
  END AS situacion,
  actualizado
FROM bot_estado
ORDER BY actualizado DESC;

COMMENT ON VIEW vw_bot_estado IS 'Lectura humana de bot_estado. Para revisar quien esta pausado y por que.';
