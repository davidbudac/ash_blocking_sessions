-- Driver for the ASH Blocking Sessions HTML report.
--
-- Usage (from sqlplus):
--   @build_report.sql <begin_time> <end_time> <con_id> <out_file>
--
-- Arguments — all four required (pass 'AUTO' / 'ALL' for defaults):
--   <begin_time>  'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= now - 2h)
--   <end_time>    'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= now)
--   <con_id>      Numeric CON_ID, or 'ALL' to include every container
--   <out_file>    File name (placed under ASH_REPORTS dir), or 'AUTO'
--
-- Connect as SYSDBA in CDB$ROOT; the script assumes ASH_ASSETS and ASH_REPORTS
-- directory objects point at <project>/assets and <project>/reports.

@@sql/00_settings.sql
@@sql/01_dirs.sql

DEFINE begin_time = &1
DEFINE end_time   = &2
DEFINE con_id_arg = &3
DEFINE out_file   = &4

@@sql/20_emit_html.sql

EXIT SUCCESS;
