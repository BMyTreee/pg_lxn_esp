-- ── init schema for lxn ────────────────────────────────────────────────────
-- Loaded into the ${PG_DB} database after role/db creation.
-- Idempotent: uses IF NOT EXISTS.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Example sensor readings table (MQTT payloads from ESP32-C3 nodes).
CREATE TABLE IF NOT EXISTS readings (
    id          BIGSERIAL PRIMARY KEY,
    node_id     TEXT        NOT NULL,
    topic       TEXT        NOT NULL,
    payload     JSONB       NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS readings_node_time_idx
    ON readings (node_id, received_at DESC);

CREATE INDEX IF NOT EXISTS readings_topic_idx
    ON readings (topic);

GRANT SELECT, INSERT, UPDATE, DELETE ON readings TO "lxn";
GRANT USAGE, SELECT ON SEQUENCE readings_id_seq TO "lxn";
