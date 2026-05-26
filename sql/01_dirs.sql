-- Create directory objects so PL/SQL can read the HTML template and write the
-- report file. Idempotent; safe to re-run. Paths point at the project root on
-- the dbmint host. Adjust if you sync the project to a different location.
--
-- Requires CREATE ANY DIRECTORY (SYSDBA has it).

CREATE OR REPLACE DIRECTORY ASH_ASSETS  AS '/home/oracle/ash_blocking_sessions/assets';
CREATE OR REPLACE DIRECTORY ASH_REPORTS AS '/home/oracle/ash_blocking_sessions/reports';
