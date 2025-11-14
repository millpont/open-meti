-- METI™ Source Ledger Bootstrap
-- One-shot entrypoint to load schema, functions, and triggers.
--
-- Run from psql:
--   \i sql/meti.sql;

\ir schema_sources.sql
\ir schema_sources_queue.sql
\ir functions.sql
\ir triggers.sql
