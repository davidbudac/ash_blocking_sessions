-- Force AWR to flush ASH samples to DBA_HIST_ACTIVE_SESS_HISTORY.
--
-- Must run from CDB$ROOT. Prints the current timestamp so you have a clean
-- upper bound for the report window.

ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

PROMPT
PROMPT === Taking AWR snapshot to flush ASH to DBA_HIST_ASH ===

BEGIN
  DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;
  DBMS_OUTPUT.PUT_LINE('SNAP_TAKEN_TS=' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS'));
END;
/

PROMPT
PROMPT === Most recent snaps ===
SET HEADING ON PAGESIZE 50 LINESIZE 200
COLUMN begin_t FOR A20
COLUMN end_t   FOR A20
SELECT snap_id,
       TO_CHAR(begin_interval_time, 'YYYY-MM-DD HH24:MI:SS') begin_t,
       TO_CHAR(end_interval_time,   'YYYY-MM-DD HH24:MI:SS') end_t
  FROM dba_hist_snapshot
 WHERE end_interval_time > SYSTIMESTAMP - INTERVAL '1' HOUR
 ORDER BY snap_id DESC
 FETCH FIRST 5 ROWS ONLY;

PROMPT
PROMPT === Blocking samples present in DBA_HIST_ASH (last hour) ===
SELECT con_id, COUNT(*) AS blocking_samples
  FROM dba_hist_active_sess_history
 WHERE sample_time > SYSTIMESTAMP - INTERVAL '1' HOUR
   AND blocking_session IS NOT NULL
 GROUP BY con_id
 ORDER BY con_id;
