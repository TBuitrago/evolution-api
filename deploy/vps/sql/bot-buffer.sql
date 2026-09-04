-- ============================================================
--  bot_buffer · agrupación de mensajes en ráfaga + deduplicación
--  Complementa a bot-estado.sql (bot_estado, bot_enviado).
--  Base: bots · usuario: n8nbots · idempotente.
--
--  Instalación (desde /docker/evolution en el VPS):
--    docker exec -i postgres-bots psql -U n8nbots -d bots < bot-buffer.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS bot_buffer (
  id         bigserial PRIMARY KEY,
  key_id     text        NOT NULL UNIQUE,      -- data.key.id → dedupe de reintentos del webhook
  remote_jid text        NOT NULL,             -- identidad normalizada del contacto
  push_name  text,
  texto      text        NOT NULL DEFAULT '',
  creado     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bot_buffer_jid_creado_idx ON bot_buffer (remote_jid, creado DESC);

COMMENT ON TABLE bot_buffer IS
  'Mensajes entrantes pendientes de responder. El flujo espera N segundos y solo la ejecución del último mensaje del contacto consume (DELETE … RETURNING) todo el buffer. Filas huérfanas se purgan con bot_buffer_purgar().';

-- Purga filas que llevan más de 1 hora sin consumirse (ej. ejecuciones caídas).
CREATE OR REPLACE FUNCTION bot_buffer_purgar() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  DELETE FROM bot_buffer WHERE creado < now() - interval '1 hour';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- La memoria del agente (tabla bot_memoria_chat) la crea el propio nodo
-- "Postgres Chat Memory" de n8n en la primera ejecución. Para reiniciar la
-- memoria de un contacto:
--   DELETE FROM bot_memoria_chat WHERE session_id = '573001234567@s.whatsapp.net';

-- Vista rápida de lo que hay en cola
CREATE OR REPLACE VIEW vw_bot_buffer AS
SELECT remote_jid,
       split_part(remote_jid, '@', 1) AS numero,
       count(*)                       AS mensajes,
       min(creado)                    AS primero,
       max(creado)                    AS ultimo,
       string_agg(left(texto, 60), ' | ' ORDER BY creado) AS vista_previa
FROM bot_buffer
GROUP BY remote_jid
ORDER BY ultimo DESC;
