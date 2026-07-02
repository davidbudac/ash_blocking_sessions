-- Build the HTML report from DBA_HIST_ACTIVE_SESS_HISTORY.
--
-- Expects DEFINEs set by the driver:
--   begin_time  ISO 'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= SYSTIMESTAMP - 2h)
--   end_time    ISO 'YYYY-MM-DDTHH24:MI:SS' or 'AUTO' (= SYSTIMESTAMP)
--   con_id_arg  '' / 'NULL' / 'ALL' for no filter, otherwise a CON_ID number
--   out_file    file name (placed in ASH_REPORTS); 'AUTO' = ash_blocking_<ts>.html
--
-- Reads assets/template.html via ASH_ASSETS, writes the rendered HTML via
-- ASH_REPORTS. Both directories must exist (created in 01_dirs.sql).

DECLARE
  c_fmt         CONSTANT VARCHAR2(40) := 'YYYY-MM-DD"T"HH24:MI:SS';

  l_begin_arg   VARCHAR2(40) := TRIM('&begin_time');
  l_end_arg     VARCHAR2(40) := TRIM('&end_time');
  l_begin       TIMESTAMP;
  l_end         TIMESTAMP;
  l_con_id_arg  VARCHAR2(32) := TRIM('&con_id_arg');
  l_con_id      NUMBER;
  l_out_file    VARCHAR2(200) := TRIM('&out_file');

  l_row_count   NUMBER;
  l_data        CLOB;
  l_meta        CLOB;
  l_tmpl        CLOB;
  l_out         CLOB;

  bf            BFILE;
  l_dst_offset  INTEGER := 1;
  l_src_offset  INTEGER := 1;
  l_lang_ctx    INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
  l_warning     INTEGER;

  -- Substitute a placeholder token with a (possibly large) CLOB value.
  -- SQL's REPLACE() caps the replacement arg at 32K (ORA-22828), so for data
  -- JSON beyond 32K we splice via DBMS_LOB: prefix || value || suffix.
  PROCEDURE replace_tag(io_lob IN OUT NOCOPY CLOB, p_tag IN VARCHAR2, p_val IN CLOB) IS
    l_pos   PLS_INTEGER;
    l_len   PLS_INTEGER;
    l_tail  PLS_INTEGER;
    l_tagln PLS_INTEGER := LENGTH(p_tag);
    l_res   CLOB;
  BEGIN
    l_pos := DBMS_LOB.INSTR(io_lob, p_tag);
    IF l_pos = 0 THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(io_lob);
    DBMS_LOB.CREATETEMPORARY(l_res, TRUE);
    IF l_pos > 1 THEN
      DBMS_LOB.COPY(l_res, io_lob, l_pos - 1, 1, 1);              -- prefix
    END IF;
    IF p_val IS NOT NULL AND DBMS_LOB.GETLENGTH(p_val) > 0 THEN
      DBMS_LOB.APPEND(l_res, p_val);                             -- value
    END IF;
    l_tail := l_len - (l_pos + l_tagln - 1);
    IF l_tail > 0 THEN
      DBMS_LOB.COPY(l_res, io_lob, l_tail,
                    DBMS_LOB.GETLENGTH(l_res) + 1, l_pos + l_tagln);  -- suffix
    END IF;
    DBMS_LOB.FREETEMPORARY(io_lob);
    io_lob := l_res;
  END replace_tag;
BEGIN
  IF l_begin_arg IS NULL OR UPPER(l_begin_arg) IN ('AUTO','') THEN
    l_begin := SYSTIMESTAMP - INTERVAL '2' HOUR;
  ELSE
    l_begin := TO_TIMESTAMP(l_begin_arg, c_fmt);
  END IF;

  IF l_end_arg IS NULL OR UPPER(l_end_arg) IN ('AUTO','') THEN
    l_end := SYSTIMESTAMP;
  ELSE
    l_end := TO_TIMESTAMP(l_end_arg, c_fmt);
  END IF;

  IF l_con_id_arg IS NULL OR UPPER(l_con_id_arg) IN ('NULL', 'ALL', '') THEN
    l_con_id := NULL;
  ELSE
    l_con_id := TO_NUMBER(l_con_id_arg);
  END IF;

  IF l_out_file IS NULL OR UPPER(l_out_file) IN ('AUTO','') THEN
    l_out_file := 'ash_blocking_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') || '.html';
  END IF;

  DBMS_OUTPUT.PUT_LINE('Window : ' || TO_CHAR(l_begin, c_fmt) || ' .. ' || TO_CHAR(l_end, c_fmt));
  DBMS_OUTPUT.PUT_LINE('CON_ID : ' || NVL(TO_CHAR(l_con_id), '(all)'));
  DBMS_OUTPUT.PUT_LINE('Output : ' || l_out_file);

  -- 1. Count first so we can warn / refuse on huge windows.
  SELECT COUNT(*)
    INTO l_row_count
    FROM dba_hist_active_sess_history
   WHERE sample_time BETWEEN l_begin AND l_end
     AND blocking_session IS NOT NULL
     AND blocking_session_status IN ('VALID', 'NOT IN WAIT', 'GLOBAL')
     AND (l_con_id IS NULL OR con_id = l_con_id);

  DBMS_OUTPUT.PUT_LINE('Blocking samples found: ' || l_row_count);

  IF l_row_count > 100000 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Too many blocking samples (' || l_row_count ||
      '). Narrow the time range or filter by CON_ID.');
  END IF;

  -- 2. Build data JSON. Left-join blocker's own sample row (when the blocker
  -- was itself active that sample) to enrich tooltips with what the blocker
  -- was doing. Compact JSON: ABSENT ON NULL skips empty fields.
  IF l_row_count = 0 THEN
    l_data := TO_CLOB('[]');
  ELSE
    WITH ash AS (
      -- Materialize the window's ASH rows into a temp segment first. Self-joining
      -- DBA_HIST_ACTIVE_SESS_HISTORY (a complex, non-mergeable UNION ALL view)
      -- directly with an ANSI outer join makes the optimizer need a ROWID for the
      -- non-key-preserved view and raises ORA-01445. Joining the materialized set
      -- to itself sidesteps that (and scans the big view only once). Keep ALL rows
      -- in the window here (not just blocked ones) so blocker rows are present for
      -- the b.* enrichment join below.
      SELECT /*+ MATERIALIZE */
             dbid, snap_id, sample_id, sample_time, instance_number,
             session_id, session_serial#, blocking_inst_id, blocking_session,
             blocking_session_serial#, blocking_session_status, event, wait_class,
             session_state, sql_id, module, action, program, machine, user_id, con_id,
             current_obj#
        FROM dba_hist_active_sess_history
       WHERE sample_time BETWEEN l_begin AND l_end
         AND (l_con_id IS NULL OR con_id = l_con_id)
    )
    SELECT JSON_ARRAYAGG(
             JSON_OBJECT(
               't'       VALUE TO_CHAR(w.sample_time, 'YYYY-MM-DD"T"HH24:MI:SS'),
               'inst'    VALUE w.instance_number,
               'sid'     VALUE w.session_id,
               'serial'  VALUE w.session_serial#,
               'bInst'   VALUE w.blocking_inst_id,
               'bSid'    VALUE w.blocking_session,
               'bSer'    VALUE w.blocking_session_serial#,
               'bStatus' VALUE w.blocking_session_status,
               'ev'      VALUE w.event,
               'wc'      VALUE w.wait_class,
               'obj'     VALUE CASE WHEN ow.owner IS NOT NULL
                                    THEN ow.owner || '.' || ow.object_name END,
               'sqlId'   VALUE w.sql_id,
               'module'  VALUE w.module,
               'action'  VALUE w.action,
               'prog'    VALUE w.program,
               'mach'    VALUE w.machine,
               'userId'  VALUE w.user_id,
               'user'    VALUE u_w.username,
               'conId'   VALUE w.con_id,
               'bEv'     VALUE b.event,
               'bSqlId'  VALUE b.sql_id,
               'bWc'     VALUE b.wait_class,
               'bState'  VALUE b.session_state,
               'bMod'    VALUE b.module,
               'bAct'    VALUE b.action,
               'bProg'   VALUE b.program,
               'bMach'   VALUE b.machine,
               'bUser'   VALUE u_b.username
               ABSENT ON NULL
             )
             ORDER BY w.sample_time, w.instance_number, w.session_id
             RETURNING CLOB
           )
      INTO l_data
      FROM ash w
      LEFT JOIN ash b
             ON b.dbid             = w.dbid
            AND b.snap_id          = w.snap_id
            AND b.sample_id        = w.sample_id
            AND b.instance_number  = NVL(w.blocking_inst_id, w.instance_number)
            AND b.session_id       = w.blocking_session
            AND b.session_serial#  = w.blocking_session_serial#
      -- Container-aware lookups: DBA_USERS/DBA_OBJECTS in CDB$ROOT can't see
      -- PDB users/objects, so join the CDB_* views on (con_id, id) instead.
      LEFT JOIN cdb_users u_w ON u_w.con_id = w.con_id AND u_w.user_id = w.user_id
      LEFT JOIN cdb_users u_b ON u_b.con_id = b.con_id AND u_b.user_id = b.user_id
      -- The object the waiter was on (CURRENT_OBJ# is -1/0 when not applicable).
      LEFT JOIN cdb_objects ow ON ow.con_id = w.con_id AND ow.object_id = w.current_obj#
     WHERE w.blocking_session IS NOT NULL
       AND w.blocking_session_status IN ('VALID', 'NOT IN WAIT', 'GLOBAL');
  END IF;

  -- 3. Meta JSON.
  SELECT JSON_OBJECT(
           'dbName'      VALUE (SELECT name FROM v$database),
           'dbId'        VALUE (SELECT dbid FROM v$database),
           'beginTime'   VALUE TO_CHAR(l_begin, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'endTime'     VALUE TO_CHAR(l_end,   'YYYY-MM-DD"T"HH24:MI:SS'),
           'generatedAt' VALUE TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'rowCount'    VALUE l_row_count,
           'conIdFilter' VALUE l_con_id,
           -- sql_id -> first 200 chars of the statement, for every SQL that ran
           -- in the window (superset of waiter + blocker SQL ids), so the report
           -- can show what the SQL was without a trip back to the DB.
           'sqlText'     VALUE (
             SELECT JSON_OBJECTAGG(x.sql_id VALUE x.txt RETURNING CLOB)
               FROM (
                 SELECT st.sql_id, MIN(DBMS_LOB.SUBSTR(st.sql_text, 200, 1)) AS txt
                   FROM dba_hist_sqltext st
                  WHERE (st.dbid, st.sql_id) IN (
                          SELECT dbid, sql_id
                            FROM dba_hist_active_sess_history
                           WHERE sample_time BETWEEN l_begin AND l_end
                             AND sql_id IS NOT NULL
                             AND (l_con_id IS NULL OR con_id = l_con_id)
                        )
                  GROUP BY st.sql_id
               ) x
           )
           ABSENT ON NULL
           RETURNING CLOB
         )
    INTO l_meta
    FROM dual;

  -- 4. Read the HTML template.
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);
  bf := BFILENAME('ASH_ASSETS', 'template.html');
  DBMS_LOB.FILEOPEN(bf, DBMS_LOB.FILE_READONLY);
  DBMS_LOB.LOADCLOBFROMFILE(
    dest_lob     => l_tmpl,
    src_bfile    => bf,
    amount       => DBMS_LOB.LOBMAXSIZE,
    dest_offset  => l_dst_offset,
    src_offset   => l_src_offset,
    bfile_csid   => NLS_CHARSET_ID('AL32UTF8'),
    lang_context => l_lang_ctx,
    warning      => l_warning
  );
  DBMS_LOB.FILECLOSE(bf);

  -- 5. Substitute placeholders via DBMS_LOB (no 32K limit; see replace_tag).
  replace_tag(l_tmpl, '__META_JSON__', l_meta);
  replace_tag(l_tmpl, '__DATA_JSON__', l_data);
  l_out := l_tmpl;

  -- 6. Write to disk via the REPORTS directory.
  DBMS_XSLPROCESSOR.CLOB2FILE(l_out, 'ASH_REPORTS', l_out_file, NLS_CHARSET_ID('AL32UTF8'));

  DBMS_OUTPUT.PUT_LINE('Wrote ' || l_out_file || ' (' || l_row_count || ' samples, ' ||
                       ROUND(DBMS_LOB.GETLENGTH(l_out)/1024) || ' KB)');

  IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
EXCEPTION
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
    RAISE;
END;
/
