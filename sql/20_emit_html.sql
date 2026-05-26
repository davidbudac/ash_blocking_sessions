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
      FROM dba_hist_active_sess_history w
      LEFT JOIN dba_hist_active_sess_history b
             ON b.dbid             = w.dbid
            AND b.snap_id          = w.snap_id
            AND b.sample_id        = w.sample_id
            AND b.instance_number  = NVL(w.blocking_inst_id, w.instance_number)
            AND b.session_id       = w.blocking_session
            AND b.session_serial#  = w.blocking_session_serial#
      LEFT JOIN dba_users u_w ON u_w.user_id = w.user_id
      LEFT JOIN dba_users u_b ON u_b.user_id = b.user_id
     WHERE w.sample_time BETWEEN l_begin AND l_end
       AND w.blocking_session IS NOT NULL
       AND w.blocking_session_status IN ('VALID', 'NOT IN WAIT', 'GLOBAL')
       AND (l_con_id IS NULL OR w.con_id = l_con_id);
  END IF;

  -- 3. Meta JSON.
  SELECT JSON_OBJECT(
           'dbName'      VALUE (SELECT name FROM v$database),
           'dbId'        VALUE (SELECT dbid FROM v$database),
           'beginTime'   VALUE TO_CHAR(l_begin, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'endTime'     VALUE TO_CHAR(l_end,   'YYYY-MM-DD"T"HH24:MI:SS'),
           'generatedAt' VALUE TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS'),
           'rowCount'    VALUE l_row_count,
           'conIdFilter' VALUE l_con_id
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

  -- 5. Substitute placeholders. REPLACE on CLOB works in 19c and returns a CLOB.
  l_out := REPLACE(l_tmpl, '__META_JSON__', l_meta);
  l_out := REPLACE(l_out,  '__DATA_JSON__', l_data);

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
