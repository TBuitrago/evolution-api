-- ============================================================================
-- Rol de PostgreSQL con permisos minimos para el bot de n8n
--
-- Reemplaza el uso de "n8nbots" (que es SUPERUSUARIO del cluster) en la
-- credencial de n8n. El rol resultante solo puede tocar las tablas del bot.
--
-- Requiere que bot-estado.sql y bot-buffer.sql ya esten instalados.
--
-- Instalacion:
--   CLAVE=$(openssl rand -hex 24); echo "GUARDA ESTO: $CLAVE"
--   docker exec -i postgres-bots psql -U n8nbots -d bots -v clave="'$CLAVE'" < bot-rol-n8n.sql
--
-- Idempotente: se puede volver a correr para rotar la clave.
-- ============================================================================

\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- 1. El rol
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bot_n8n') THEN
    CREATE ROLE bot_n8n LOGIN;
    RAISE NOTICE 'rol bot_n8n creado';
  ELSE
    RAISE NOTICE 'rol bot_n8n ya existia, se le actualiza la clave';
  END IF;
END $$;

ALTER ROLE bot_n8n WITH PASSWORD :clave;
ALTER ROLE bot_n8n NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

-- ----------------------------------------------------------------------------
-- 2. Acceso a la base y al schema
--
-- CREATE sobre el schema es OBLIGATORIO: el nodo "Postgres Chat Memory" de n8n
-- ejecuta CREATE TABLE IF NOT EXISTS bot_memoria_chat en cada corrida, y
-- PostgreSQL evalua el permiso ANTES del IF NOT EXISTS. Sin CREATE, el nodo
-- falla siempre, incluso con la tabla ya creada.
--
-- El alcance real de ese permiso es acotado: bot_n8n puede crear tablas
-- propias en public, pero NO puede borrar ni alterar las que pertenecen a
-- n8nbots, ni leer ninguna tabla sobre la que no tenga un GRANT explicito.
-- ----------------------------------------------------------------------------
GRANT CONNECT ON DATABASE bots TO bot_n8n;
GRANT USAGE, CREATE ON SCHEMA public TO bot_n8n;

-- ----------------------------------------------------------------------------
-- 3. Datos del bot: lectura y escritura, nada de DDL
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON bot_estado, bot_enviado, bot_buffer TO bot_n8n;

-- bot_buffer.id es bigserial y necesita su secuencia.
GRANT USAGE, SELECT ON SEQUENCE bot_buffer_id_seq TO bot_n8n;

-- ----------------------------------------------------------------------------
-- 4. Vistas y funciones de purga
--
-- Las funciones corren con los permisos de QUIEN LAS LLAMA (SECURITY INVOKER,
-- el predeterminado), asi que se apoyan en los DELETE concedidos arriba.
-- ----------------------------------------------------------------------------
GRANT SELECT ON vw_bot_estado, vw_bot_buffer TO bot_n8n;
GRANT EXECUTE ON FUNCTION bot_enviado_purgar(), bot_buffer_purgar() TO bot_n8n;

-- ----------------------------------------------------------------------------
-- 5. Resumen
-- ----------------------------------------------------------------------------
\echo ''
\echo 'Permisos concedidos a bot_n8n:'
SELECT table_name AS objeto,
       string_agg(privilege_type, ', ' ORDER BY privilege_type) AS permisos
FROM information_schema.role_table_grants
WHERE grantee = 'bot_n8n'
GROUP BY table_name
ORDER BY table_name;

\echo 'Atributos del rol (todo debe estar en f salvo rolcanlogin):'
SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin
FROM pg_roles WHERE rolname = 'bot_n8n';
