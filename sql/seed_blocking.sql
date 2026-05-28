-- Seed realistic blocking scenarios in PDB1 for the demo.
--
-- Creates ASH_TEST schema (drops + recreates), populates a small lock target
-- table, then submits a batch of DBMS_SCHEDULER jobs that produce:
--
--   * Pattern A: one blocker on row 1, three waiters fighting for the same row
--     -> "enq: TX - row lock contention", many-to-one fan-in.
--   * Pattern B: chained blocking (A blocks B blocks C).
--   * Pattern C: a session holding LOCK TABLE ... EXCLUSIVE, two waiters doing
--     DML -> "enq: TM - contention" (a different wait event than TX).
--   * Pattern D: a session holding a DBMS_LOCK user lock, two waiters requesting
--     the same lock -> "enq: UL - contention" (a third distinct wait event).
--
-- Patterns A-D all start at the same instant, so the report shows MULTIPLE
-- concurrent wait chains and MORE THAN ONE wait type at once (not just TX).
-- (Distinct wait *classes* such as Concurrency/buffer-busy are intentionally
-- not seeded here — they can't be produced deterministically from sleeping
-- jobs; the offline demo dataset covers that variety for UI work.)
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
  -- A previous run's demo jobs (and their sessions) may still be alive — they
  -- sleep up to 240s. Stop the jobs and kill any ASH_TEST sessions first, or
  -- DROP USER fails with ORA-01940 (user currently connected) and we inherit a
  -- dirty schema (e.g. a leftover EXCLUSIVE table lock that collapses chains).
  FOR j IN (SELECT owner, job_name FROM dba_scheduler_running_jobs
             WHERE job_name LIKE 'ASH_DEMO_%') LOOP
    BEGIN DBMS_SCHEDULER.STOP_JOB(j.owner||'.'||j.job_name, force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;

  FOR s IN (SELECT sid, serial# FROM v$session WHERE username = 'ASH_TEST') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION '''||s.sid||','||s.serial#||
                        ''' IMMEDIATE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;

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

-- Separate table for the TM (table-lock) pattern. It MUST be distinct from
-- LOCK_TARGET: a LOCK TABLE ... EXCLUSIVE on the shared table would block the
-- TX row-lock patterns too, collapsing every chain into a single TM wait.
CREATE TABLE ASH_TEST.LOCK_TARGET_TM (
  id     NUMBER PRIMARY KEY,
  v      NUMBER,
  label  VARCHAR2(60)
);
INSERT INTO ASH_TEST.LOCK_TARGET_TM VALUES (1, 0, 'tm row 1');
INSERT INTO ASH_TEST.LOCK_TARGET_TM VALUES (2, 0, 'tm row 2');
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

  ---------------------------------------------------------------
  -- Pattern C: TM - contention. One session locks the whole table in
  -- EXCLUSIVE mode; two DML sessions then block on the table lock itself
  -- (before any row lock) -> "enq: TM - contention".
  ---------------------------------------------------------------
  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_TM_HOLD',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('MAINT_REORG', 'LOCK_TABLE_EXCL');
                       LOCK TABLE ASH_TEST.LOCK_TARGET_TM IN EXCLUSIVE MODE;
                       DBMS_LOCK.SLEEP(240);
                       ROLLBACK;
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Holds an EXCLUSIVE table lock for 240s');

  FOR i IN 1..2 LOOP
    DBMS_SCHEDULER.CREATE_JOB(
      job_name   => 'ASH_TEST.ASH_DEMO_TM_W_' || i,
      job_type   => 'PLSQL_BLOCK',
      job_action => q'[BEGIN
                         DBMS_APPLICATION_INFO.SET_MODULE('SALES_SVC', 'INSERT_ORDER');
                         DBMS_LOCK.SLEEP(8);  -- let the EXCLUSIVE locker win first
                         UPDATE ASH_TEST.LOCK_TARGET_TM SET v = v + 1 WHERE id = 1;
                         ROLLBACK;
                       END;]',
      start_date => SYSTIMESTAMP,
      enabled    => TRUE,
      auto_drop  => TRUE,
      comments   => 'TM waiter ' || i || ' (DML blocked by table lock)');
  END LOOP;

  ---------------------------------------------------------------
  -- Pattern D: UL - contention. One session holds a named DBMS_LOCK user
  -- lock in EXCLUSIVE mode; two others request the same lock and wait
  -- -> "enq: UL - contention" (a distinct wait event again).
  ---------------------------------------------------------------
  DBMS_SCHEDULER.CREATE_JOB(
    job_name   => 'ASH_TEST.ASH_DEMO_UL_HOLD',
    job_type   => 'PLSQL_BLOCK',
    job_action => q'[DECLARE l_h VARCHAR2(128); l_r NUMBER;
                     BEGIN
                       DBMS_APPLICATION_INFO.SET_MODULE('PRICING_SVC', 'HOLD_USER_LOCK');
                       DBMS_LOCK.ALLOCATE_UNIQUE('ASH_DEMO_UL', l_h);
                       l_r := DBMS_LOCK.REQUEST(l_h, DBMS_LOCK.X_MODE, release_on_commit => FALSE);
                       DBMS_LOCK.SLEEP(240);
                       l_r := DBMS_LOCK.RELEASE(l_h);
                     END;]',
    start_date => SYSTIMESTAMP,
    enabled    => TRUE,
    auto_drop  => TRUE,
    comments   => 'Holds a DBMS_LOCK user lock for 240s');

  FOR i IN 1..2 LOOP
    DBMS_SCHEDULER.CREATE_JOB(
      job_name   => 'ASH_TEST.ASH_DEMO_UL_W_' || i,
      job_type   => 'PLSQL_BLOCK',
      job_action => q'[DECLARE l_h VARCHAR2(128); l_r NUMBER;
                       BEGIN
                         DBMS_APPLICATION_INFO.SET_MODULE('PRICING_SVC', 'WAIT_USER_LOCK');
                         DBMS_LOCK.SLEEP(8);  -- let the holder grab it first
                         DBMS_LOCK.ALLOCATE_UNIQUE('ASH_DEMO_UL', l_h);
                         l_r := DBMS_LOCK.REQUEST(l_h, DBMS_LOCK.X_MODE, release_on_commit => FALSE);
                         l_r := DBMS_LOCK.RELEASE(l_h);
                       END;]',
      start_date => SYSTIMESTAMP,
      enabled    => TRUE,
      auto_drop  => TRUE,
      comments   => 'UL waiter ' || i || ' (waits on user lock)');
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('SEED_START_TS=' || TO_CHAR(l_now, 'YYYY-MM-DD"T"HH24:MI:SS'));
END;
/

PROMPT
PROMPT === Jobs submitted. Sleep ~4 min, then run take_snap.sql ===
