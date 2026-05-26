-- Seed realistic blocking scenarios in PDB1 for the demo.
--
-- Creates ASH_TEST schema (drops + recreates), populates a small lock target
-- table, then submits a batch of DBMS_SCHEDULER jobs that produce:
--
--   * Pattern A: one blocker on row 1, three waiters fighting for the same row
--     -> "enq: TX - row lock contention", many-to-one fan-in.
--   * Pattern B: chained blocking (A blocks B blocks C).
--
-- Each job sleeps ~4 minutes while holding/waiting, then rolls back. Jobs run
-- in their own dedicated sessions so they show up in V$/DBA_HIST ASH like real
-- foreground sessions.
--
-- Prints the start timestamp (UTC + local) and the suggested report window.

ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET NLS_DATE_FORMAT      = 'YYYY-MM-DD HH24:MI:SS';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

PROMPT
PROMPT === Setting up ASH_TEST schema in PDB1 ===

DECLARE
  e_no_user EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_no_user, -1918);
BEGIN
  -- Drop the user (and any leftover jobs underneath) so we start clean.
  EXECUTE IMMEDIATE 'DROP USER ASH_TEST CASCADE';
EXCEPTION WHEN e_no_user THEN NULL;
END;
/

CREATE USER ASH_TEST IDENTIFIED BY "ash_test_p4ss" QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, CREATE SESSION TO ASH_TEST;
GRANT EXECUTE ON DBMS_LOCK TO ASH_TEST;
GRANT CREATE JOB TO ASH_TEST;

CREATE TABLE ASH_TEST.LOCK_TARGET (
  id     NUMBER PRIMARY KEY,
  v      NUMBER,
  label  VARCHAR2(60)
);

INSERT INTO ASH_TEST.LOCK_TARGET VALUES (1, 0, 'row 1');
INSERT INTO ASH_TEST.LOCK_TARGET VALUES (2, 0, 'row 2');
INSERT INTO ASH_TEST.LOCK_TARGET VALUES (3, 0, 'row 3');
COMMIT;

PROMPT
PROMPT === Submitting blocking jobs ===

DECLARE
  l_now TIMESTAMP := SYSTIMESTAMP;
BEGIN
  -- Drop any stale demo jobs from a previous run (in case ASH_TEST CASCADE
  -- didn't catch a job owned by SYS in this schema).
  FOR j IN (SELECT job_name, owner
              FROM dba_scheduler_jobs
             WHERE job_name LIKE 'ASH_DEMO_%') LOOP
    BEGIN
      DBMS_SCHEDULER.DROP_JOB(j.owner||'.'||j.job_name, force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  ---------------------------------------------------------------
  -- Pattern A: one blocker, three waiters on row 1.
  -- Each job tags itself with a distinct MODULE/ACTION so the report's
  -- identifier toggles show meaningful per-SID variation.
  ---------------------------------------------------------------
  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_BLK_R1',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('ETL_LOAD', 'HOLD_ROW1');
                       UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 1;
                       DBMS_LOCK.SLEEP(240);
                       ROLLBACK;
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Holds row 1 lock for 240s');

  FOR i IN 1..3 LOOP
    DBMS_SCHEDULER.CREATE_JOB(
      job_name   => 'ASH_TEST.ASH_DEMO_W1_' || i,
      job_type   => 'PLSQL_BLOCK',
      job_action => q'[DECLARE
                         l_action VARCHAR2(64) := 'POST_INVOICE_' || DBMS_RANDOM.STRING('U',4);
                       BEGIN
                         DBMS_APPLICATION_INFO.SET_MODULE('ORDERS_API', l_action);
                         DBMS_LOCK.SLEEP(8);  -- let the blocker grab the row first
                         UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 1;
                         ROLLBACK;
                       END;]',
      start_date => SYSTIMESTAMP,
      enabled    => TRUE,
      auto_drop  => TRUE,
      comments   => 'Waiter ' || i || ' on row 1');
  END LOOP;

  ---------------------------------------------------------------
  -- Pattern B: chained blocking (A holds 2, B holds 3 then waits on 2,
  -- C waits on 3). After the storm, B-C-A form an A <- B <- C chain.
  ---------------------------------------------------------------
  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_CHAIN_A',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('NIGHTLY_BATCH', 'CHAIN_ROOT');
                       UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 2;
                       DBMS_LOCK.SLEEP(240);
                       ROLLBACK;
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Chain root: holds row 2');

  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_CHAIN_B',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('NIGHTLY_BATCH', 'CHAIN_MID');
                       DBMS_LOCK.SLEEP(5);
                       UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 3;
                       UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 2;
                       ROLLBACK;
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Chain middle: holds row 3, waits on row 2');

  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_CHAIN_C',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('NIGHTLY_BATCH', 'CHAIN_LEAF');
                       DBMS_LOCK.SLEEP(15);
                       UPDATE ASH_TEST.LOCK_TARGET SET v = v + 1 WHERE id = 3;
                       ROLLBACK;
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Chain leaf: waits on row 3 (which waits on row 2)');

  DBMS_OUTPUT.PUT_LINE('SEED_START_TS=' || TO_CHAR(l_now, 'YYYY-MM-DD"T"HH24:MI:SS'));
END;
/

PROMPT
PROMPT === Jobs submitted. Sleep ~4 min, then run take_snap.sql ===
