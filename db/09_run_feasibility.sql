-- =====================================================================
--  Sanchari · 09_run_feasibility.sql
--  Purpose    : Fill feasibility_run and violation by running the
--               feasibility check on every trip that is not cancelled.
--  Author     : Swara
--  Runs after : 08a_feasibility_engine.sql
--
--  These two tables are never typed in - they are the engine's OUTPUT.
--  The loop calls p_check_trip once per trip, in trip_id order, and each
--  call prints one NOTICE line with that trip's result.
--
--  Expected: 32 runs (34 trips minus the 2 cancelled ones). Every
--  ordinary trip scores 100. The 8 test trips (T27-T34 in trips.csv)
--  each fail exactly the one rule they were built to break.
-- =====================================================================

DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT trip_id FROM trip WHERE status <> 'cancelled' ORDER BY trip_id
    LOOP
        CALL p_check_trip(t.trip_id);
    END LOOP;
END $$;

-- =====================================================================
--  Sanity check:
--      SELECT * FROM v_trip_health ORDER BY trip_id;
--      SELECT rule_code, severity, count(*) FROM violation
--      GROUP  BY rule_code, severity ORDER BY rule_code;
-- =====================================================================
