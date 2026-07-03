-- Driver for the ASH Blocking Sessions HTML report.
--
-- Usage (from sqlplus):
--   @build_report.sql <begin_time> <end_time>
--
-- Arguments — both required (pass 'AUTO' for defaults):
--   <begin_time>  'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= now - 2h)
--   <end_time>    'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= now)
--
-- The report always covers every container in the connected CDB.
--
-- Fully read-only: only SELECTs (DBA_HIST_*, CDB_USERS, CDB_OBJECTS,
-- V$DATABASE) plus session-scoped NLS settings. No DDL, no DML, no directory
-- objects, no server-side file access. The JSON payloads are printed to
-- stdout between marker lines; run_report.sh splices them into
-- assets/template.html and writes the HTML on the client side.
--
-- Connect as SYSDBA in CDB$ROOT, or any common user with SELECT_CATALOG_ROLE.

@@sql/00_settings.sql

DEFINE begin_time = &1
DEFINE end_time   = &2

@@sql/20_emit_html.sql

EXIT SUCCESS;
