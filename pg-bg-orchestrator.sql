-- ============================================================================
-- ASYNCHRONOUS RESILIENT ORCHESTRATION FRAMEWORK (AROF) 
-- EDITION: Diamond (Production Ready - Secured)
-- ARCHITECTURE: Procedure-Based + RAM Arrays + Zero-Subtransaction Lock
-- SECURITY: Revoke PUBLIC + Search Path Hijacking Protection
-- COMPATIBILITY: PostgreSQL 10+ (Native MD5)
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- PHASE 1: Extensions, Schema and Enums
-- ----------------------------------------------------------------------------

-- ============================================================================
-- EXTENSION AND SCHEMA
-- What is it?: These are the foundations of our tool. "pg_background" is a 
--            database extension, and "bg" is the dedicated schema (namespace).
-- What is it for?: The extension allows the DB to run multiple tasks in the 
--                  background without freezing the user's screen. The schema 
--                  keeps our code isolated from the client's business tables.
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_background;
CREATE SCHEMA IF NOT EXISTS bg;

-- ============================================================================
-- STATE TYPES (ENUMS)
-- What are they?: Dictionaries with permitted keywords for the system.
-- What are they for?: 
--   * execution_mode: Tells the system how to run the job (Sequential, Pool, etc).
--   * run_status: High-level status of a general job (Running, Completed, etc).
--   * task_status: Low-level status of a single step (Pending, Success, Failed).
-- ============================================================================
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'execution_mode' AND typnamespace = 'bg'::regnamespace) THEN
        -- 🚀 UPDATE: 'PARALLEL_INITIAL' renamed to 'CONCURRENT_ORDERED' for technical clarity
        CREATE TYPE bg.execution_mode AS ENUM ('SEQUENTIAL_STRICT', 'SEQUENTIAL_NORMAL', 'CONCURRENT_ORDERED', 'RANDOM');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'run_status' AND typnamespace = 'bg'::regnamespace) THEN
        CREATE TYPE bg.run_status AS ENUM ('INITIALIZING', 'RUNNING', 'COMPLETED', 'FAILED', 'RECOVERING');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_status' AND typnamespace = 'bg'::regnamespace) THEN
        CREATE TYPE bg.task_status AS ENUM ('PENDING', 'RUNNING', 'SUCCESS', 'FAILED', 'KILLED');
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- PHASE 2: Immutable and Decoupled Persistence
-- ----------------------------------------------------------------------------

-- ============================================================================
-- TABLE: bg.cat_queries (Query Catalog)
-- What is it?: Central library storing the raw SQL texts to be executed.
-- What is it for?: Instead of storing the same 1,000 queries repeatedly, the 
--                  system deduplicates them using an MD5 hash. Saves space.
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.cat_queries (
    query_id SERIAL PRIMARY KEY,
    query_hash VARCHAR(32) UNIQUE NOT NULL, -- Capped at 32 chars for MD5
    query_text TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CLOCK_TIMESTAMP()
);

-- ============================================================================
-- TABLE: bg.def_jobs (Job Templates)
-- What is it?: The master blueprint for a general Job.
-- What is it for?: Defines the job name, timeout limits, max retries, and 
--                  the maximum allowed parallel processes (safety valve).
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.def_jobs (
    job_id SERIAL PRIMARY KEY,
    job_name VARCHAR(100) UNIQUE NOT NULL,
    mode bg.execution_mode NOT NULL,
    max_parallel_processes INT DEFAULT 1 CHECK (max_parallel_processes >= 1),
    timeout_seconds INT NOT NULL DEFAULT 300 CHECK (timeout_seconds > 0),
    max_retries INT NOT NULL DEFAULT 0 CHECK (max_retries >= 0),
    allocation_policy VARCHAR(20) DEFAULT 'ADAPTIVE' CHECK (allocation_policy IN ('ADAPTIVE', 'STRICT')),
    execution_notes TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CLOCK_TIMESTAMP()
);

-- ============================================================================
-- TABLE: bg.def_tasks (Task Steps)
-- What is it?: The recipe linking queries to a specific Job.
-- What is it for?: Instructs the orchestrator on the exact execution order.
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.def_tasks (
    task_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES bg.def_jobs(job_id) ON DELETE CASCADE,
    query_id INT NOT NULL REFERENCES bg.cat_queries(query_id),
    execution_order INT NOT NULL CHECK (execution_order > 0),
    CONSTRAINT unique_task_order_per_job UNIQUE (job_id, execution_order)
);

-- ============================================================================
-- TABLE: bg.run_jobs (Job Execution History)
-- What is it?: The main execution logbook.
-- What is it for?: Records every time a Job is triggered, storing start times, 
--                  end times, and the final overarching status.
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.run_jobs (
    run_id SERIAL PRIMARY KEY,
    job_id INT NOT NULL REFERENCES bg.def_jobs(job_id),
    status bg.run_status DEFAULT 'INITIALIZING',
    monitor_pid INT,
    started_at TIMESTAMP DEFAULT CLOCK_TIMESTAMP(),
    ended_at TIMESTAMP
);

-- ============================================================================
-- TABLE: bg.run_tasks (Live Task Queue)
-- What is it?: The waiting room and report card for every single step.
-- What is it for?: Real-time queue tracking. Logs pending tasks, running tasks, 
--                  and captures exact error messages if a failure occurs.
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.run_tasks (
    run_task_id SERIAL PRIMARY KEY,
    run_id INT NOT NULL REFERENCES bg.run_jobs(run_id) ON DELETE CASCADE,
    query_id INT NOT NULL REFERENCES bg.cat_queries(query_id),
    execution_order INT NOT NULL,
    status bg.task_status DEFAULT 'PENDING',
    child_pid INT,
    attempt INT DEFAULT 1,
    started_at TIMESTAMP,
    ended_at TIMESTAMP,
    error_log TEXT
);

-- ============================================================================
-- TABLE: bg.run_tasks_errors_history (Forensic Black Box)
-- What is it?: Immutable ledger archiving the true history of failures.
-- What is it for?: Carefully records every scar and error before the engine 
--                  clears the live queue for a retry. Archives status & SQL.
-- ============================================================================
CREATE TABLE IF NOT EXISTS bg.run_tasks_errors_history (
    history_id SERIAL PRIMARY KEY,
    run_task_id INT NOT NULL,
    run_id INT NOT NULL,
    execution_order INT NOT NULL,
    task_status VARCHAR(20) NOT NULL,
    failed_attempt INT NOT NULL,
    query_text TEXT NOT NULL,
    error_log TEXT NOT NULL,
    registered_at TIMESTAMP DEFAULT CLOCK_TIMESTAMP()
);

-- ============================================================================
-- INDEXES (Accelerators)
-- What are they?: Like the index at the back of a book.
-- What are they for?: Helps the database find queue information instantly 
--                     without scanning the entire table row by row.
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_cat_queries_hash ON bg.cat_queries(query_hash);
CREATE INDEX IF NOT EXISTS idx_run_tasks_lookup ON bg.run_tasks(run_id, status);

-- ----------------------------------------------------------------------------
-- PHASE 3: Base Concurrency Engines (Lock-Free & Subtransaction-Free)
-- ----------------------------------------------------------------------------

-- ============================================================================
-- FUNCTION: bg.register_query (The Receptionist)
-- What is it?: Registers new queries into the catalog.
-- What is it for?: Receives raw SQL, checks if it already exists via MD5 hash. 
--                  If it doesn't, it saves it. Returns the internal query ID.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.register_query(p_sql TEXT) RETURNS INT AS $$
DECLARE v_id INT;
BEGIN
    INSERT INTO bg.cat_queries (query_hash, query_text) 
    VALUES (md5(p_sql), p_sql) 
    ON CONFLICT (query_hash) DO UPDATE SET query_hash = EXCLUDED.query_hash 
    RETURNING query_id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.register_query(TEXT) FROM PUBLIC;

-- ============================================================================
-- PROCEDURE: bg.bg_task_executor (The Worker / Child Process)
-- What is it?: The process executing the heavy lifting for each step.
-- What is it for?: Flags the task as RUNNING, executes the actual SQL code, 
--                  and reports back a SUCCESS or logs the FAILED message.
-- ============================================================================
CREATE OR REPLACE PROCEDURE bg.bg_task_executor(p_run_task_id INT) AS $$
DECLARE 
    v_query_text TEXT;
BEGIN
    PERFORM pg_catalog.set_config('search_path', 'bg, public, pg_temp', false);

    SELECT cq.query_text INTO v_query_text 
    FROM bg.run_tasks rt JOIN bg.cat_queries cq ON rt.query_id = cq.query_id 
    WHERE rt.run_task_id = p_run_task_id;

    UPDATE bg.run_tasks SET status = 'RUNNING', started_at = pg_catalog.clock_timestamp(), child_pid = pg_catalog.pg_backend_pid() WHERE run_task_id = p_run_task_id;
    COMMIT; 

    BEGIN
        EXECUTE v_query_text; 
        UPDATE bg.run_tasks SET status = 'SUCCESS', ended_at = pg_catalog.clock_timestamp() WHERE run_task_id = p_run_task_id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE bg.run_tasks SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), error_log = SQLERRM WHERE run_task_id = p_run_task_id;
    END;
    
    COMMIT; 
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON PROCEDURE bg.bg_task_executor(INT) FROM PUBLIC;




-- ============================================================================
-- PROCEDURE: bg.bg_job_orchestrator (The Boss / Parent Process)
-- What is it?: The main brain controlling when and how workers operate.
-- What is it for?: Reads pending tasks, launches workers, and monitors them 
--                  with a stopwatch. If a worker exceeds the timeout limit, 
--                  it kills the process to prevent DB freezes. Handles retries.
-- SECURITY PATCH: Optimistic Locking applied to prevent Phantom Aborts.
-- ============================================================================
CREATE OR REPLACE PROCEDURE bg.bg_job_orchestrator(p_run_id INT) AS $$
DECLARE
    v_mode bg.execution_mode; v_timeout INT; v_max_retries INT; v_max_parallel INT; v_allocation_policy VARCHAR;
    v_child_pid INT; v_current_status bg.task_status; v_curr_attempt INT;
    v_task_start TIMESTAMP; v_active_slots INT; v_run_task_id INT;
    v_task_list INT[]; v_running_list INT[]; v_failed_list INT[]; v_task_started_at TIMESTAMP;
    v_launch_success BOOLEAN; v_throttled BOOLEAN := FALSE;
BEGIN
    PERFORM pg_catalog.set_config('search_path', 'bg, public, pg_temp', false);

    UPDATE bg.run_jobs SET monitor_pid = pg_catalog.pg_backend_pid(), status = 'RUNNING', started_at = pg_catalog.clock_timestamp() WHERE run_id = p_run_id;
    COMMIT;

    -- LEEMOS LA POLÍTICA DEL CLIENTE
    SELECT dj.mode, dj.timeout_seconds, dj.max_retries, dj.max_parallel_processes, dj.allocation_policy
    INTO v_mode, v_timeout, v_max_retries, v_max_parallel, v_allocation_policy
    FROM bg.run_jobs rj JOIN bg.def_jobs dj ON rj.job_id = dj.job_id WHERE rj.run_id = p_run_id;

    IF v_mode IN ('SEQUENTIAL_STRICT', 'SEQUENTIAL_NORMAL') THEN
        v_task_list := ARRAY(SELECT run_task_id FROM bg.run_tasks WHERE run_id = p_run_id ORDER BY execution_order ASC);
        FOREACH v_run_task_id IN ARRAY v_task_list LOOP
            WHILE TRUE LOOP
                v_launch_success := TRUE;
                BEGIN
                    SELECT public.pg_background_launch(pg_catalog.format('CALL bg.bg_task_executor(%L)', v_run_task_id)) INTO v_child_pid;
                EXCEPTION WHEN OTHERS THEN
                    v_launch_success := FALSE;
                END;

                IF NOT v_launch_success THEN
                    IF v_allocation_policy = 'STRICT' THEN
                        -- FAIL-FAST MODO STRICT
                        UPDATE bg.run_jobs SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), execution_notes = '🛑 ABORTED: Hardware slot limit reached under STRICT policy.' WHERE run_id = p_run_id;
                        UPDATE bg.run_tasks SET status = 'KILLED', error_log = 'Hardware capacity abort' WHERE run_id = p_run_id AND status = 'PENDING';
                        COMMIT; RETURN;
                    ELSE
                        -- AVISO MODO ADAPTIVE
                        IF NOT v_throttled THEN
                            UPDATE bg.run_jobs SET execution_notes = '⚠️ ADAPTIVE: Running in degraded mode. Hardware slots saturated.' WHERE run_id = p_run_id;
                            v_throttled := TRUE;
                        END IF;
                        COMMIT; PERFORM pg_catalog.pg_sleep(0.5); CONTINUE; 
                    END IF;
                END IF;

                v_task_start := pg_catalog.clock_timestamp(); 
                WHILE TRUE LOOP
                    COMMIT; PERFORM pg_catalog.pg_sleep(0.5); 
                    SELECT status INTO v_current_status FROM bg.run_tasks WHERE run_task_id = v_run_task_id;
                    IF v_current_status IN ('SUCCESS', 'FAILED') THEN EXIT; END IF;

                    IF EXTRACT(EPOCH FROM (pg_catalog.clock_timestamp() - v_task_start)) >= v_timeout THEN
                        PERFORM pg_catalog.pg_cancel_backend(v_child_pid); 
                        UPDATE bg.run_tasks SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), error_log = 'Killed by Parent (Strict Timeout)' WHERE run_task_id = v_run_task_id AND status = 'RUNNING';
                        COMMIT; v_current_status := 'FAILED'; EXIT;
                    END IF;

                    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stat_activity WHERE pid = v_child_pid AND backend_type = 'pg_background') THEN
                        UPDATE bg.run_tasks SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), error_log = 'Worker aborted by OS' WHERE run_task_id = v_run_task_id AND status = 'RUNNING';
                        COMMIT; v_current_status := 'FAILED'; EXIT;
                    END IF;
                END LOOP;

                IF v_current_status = 'SUCCESS' THEN EXIT; END IF;

                SELECT attempt INTO v_curr_attempt FROM bg.run_tasks WHERE run_task_id = v_run_task_id;
                IF v_curr_attempt <= v_max_retries THEN
                    UPDATE bg.run_tasks SET attempt = v_curr_attempt + 1, status = 'PENDING', error_log = NULL WHERE run_task_id = v_run_task_id AND status = 'FAILED';
                    COMMIT;
                ELSE
                    IF v_mode = 'SEQUENTIAL_STRICT' THEN
                        UPDATE bg.run_jobs SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp() WHERE run_id = p_run_id;
                        COMMIT; RETURN;
                    END IF;
                    EXIT; 
                END IF;
            END LOOP;
        END LOOP;

    ELSE
        WHILE EXISTS (SELECT 1 FROM bg.run_tasks WHERE run_id = p_run_id AND status IN ('PENDING', 'RUNNING')) LOOP
            COMMIT; 
            
            v_running_list := ARRAY(SELECT run_task_id FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'RUNNING');
            FOREACH v_run_task_id IN ARRAY v_running_list LOOP
                SELECT child_pid, started_at INTO v_child_pid, v_task_started_at FROM bg.run_tasks WHERE run_task_id = v_run_task_id;

                IF EXTRACT(EPOCH FROM (pg_catalog.clock_timestamp() - v_task_started_at)) >= v_timeout THEN
                    PERFORM pg_catalog.pg_cancel_backend(v_child_pid);
                    UPDATE bg.run_tasks SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), error_log = 'Killed by Parent (Concurrent Timeout)' WHERE run_task_id = v_run_task_id AND status = 'RUNNING';
                    COMMIT;
                ELSIF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stat_activity WHERE pid = v_child_pid AND backend_type = 'pg_background') THEN
                    UPDATE bg.run_tasks SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), error_log = 'Concurrent worker aborted by OS' WHERE run_task_id = v_run_task_id AND status = 'RUNNING';
                    COMMIT;
                END IF;
            END LOOP;

            v_failed_list := ARRAY(SELECT run_task_id FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'FAILED' AND error_log IS NOT NULL AND attempt <= v_max_retries);
            FOREACH v_run_task_id IN ARRAY v_failed_list LOOP
                SELECT attempt INTO v_curr_attempt FROM bg.run_tasks WHERE run_task_id = v_run_task_id;
                IF v_curr_attempt <= v_max_retries THEN
                    UPDATE bg.run_tasks SET attempt = v_curr_attempt + 1, status = 'PENDING', error_log = NULL WHERE run_task_id = v_run_task_id AND status = 'FAILED';
                    COMMIT;
                END IF;
            END LOOP;

            SELECT COUNT(*) INTO v_active_slots FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'RUNNING';
            
            WHILE v_active_slots < v_max_parallel LOOP
                v_run_task_id := NULL; 
                
                IF v_mode = 'RANDOM' THEN
                    SELECT run_task_id INTO v_run_task_id FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'PENDING' ORDER BY RANDOM() LIMIT 1;
                ELSE
                    SELECT run_task_id INTO v_run_task_id FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'PENDING' ORDER BY execution_order ASC LIMIT 1;
                END IF;

                EXIT WHEN v_run_task_id IS NULL; 

                v_launch_success := TRUE;
                BEGIN
                    SELECT public.pg_background_launch(pg_catalog.format('CALL bg.bg_task_executor(%L)', v_run_task_id)) INTO v_child_pid;
                EXCEPTION WHEN OTHERS THEN
                    v_launch_success := FALSE;
                END;

                IF v_launch_success THEN
                    UPDATE bg.run_tasks SET status = 'RUNNING', started_at = pg_catalog.clock_timestamp(), child_pid = v_child_pid WHERE run_task_id = v_run_task_id;
                    COMMIT;
                    v_active_slots := v_active_slots + 1;
                ELSE
                    IF v_allocation_policy = 'STRICT' THEN
                        -- FAIL-FAST MODO STRICT
                        UPDATE bg.run_jobs SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp(), execution_notes = '🛑 ABORTED: Hardware slot limit reached under STRICT policy.' WHERE run_id = p_run_id;
                        
                        -- Aniquilar hijos vivos para liberar recursos rápido
                        FOR v_child_pid IN (SELECT child_pid FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'RUNNING' AND child_pid IS NOT NULL) LOOP
                            PERFORM pg_catalog.pg_cancel_backend(v_child_pid);
                        END LOOP;

                        UPDATE bg.run_tasks SET status = 'KILLED', error_log = 'Hardware capacity abort' WHERE run_id = p_run_id AND status IN ('PENDING', 'RUNNING');
                        COMMIT; RETURN;
                    ELSE
                        -- AVISO MODO ADAPTIVE
                        IF NOT v_throttled THEN
                            UPDATE bg.run_jobs SET execution_notes = '⚠️ ADAPTIVE: Running in degraded mode. Hardware slots saturated.' WHERE run_id = p_run_id;
                            v_throttled := TRUE;
                            COMMIT;
                        END IF;
                        EXIT; -- Frenamos los lanzamientos temporalmente
                    END IF;
                END IF;

            END LOOP;

            PERFORM pg_catalog.pg_sleep(0.5); 
        END LOOP;
    END IF;
    
    IF EXISTS (SELECT 1 FROM bg.run_tasks WHERE run_id = p_run_id AND status = 'FAILED') THEN
        UPDATE bg.run_jobs SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp() WHERE run_id = p_run_id;
    ELSE
        UPDATE bg.run_jobs SET status = 'COMPLETED', ended_at = pg_catalog.clock_timestamp() WHERE run_id = p_run_id;
    END IF;
    COMMIT;
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON PROCEDURE bg.bg_job_orchestrator(INT) FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- PHASE 4: High Performance API (UPSERT and CTEs)
-- ----------------------------------------------------------------------------

-- ============================================================================
-- FUNCTION: bg.create_job_definition (The Template Creator)
-- What is it?: Function registering a new workflow in the system.
-- What is it for?: Takes a job name and its task array. If it's new, it saves it. 
--                  If it exists, it securely updates the latest steps.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.create_job_definition(
    p_job_name VARCHAR(100), p_mode bg.execution_mode, p_queries TEXT[], p_timeout_seconds INT DEFAULT 300, p_max_retries INT DEFAULT 0, p_max_parallel_processes INT DEFAULT 1,
    p_allocation_policy VARCHAR DEFAULT 'ADAPTIVE' -- 👈 NUEVO PARÁMETRO
) RETURNS INT AS $$
DECLARE v_job_id INT; v_query_id INT; v_query_text TEXT; v_order INT := 1;
BEGIN
    INSERT INTO bg.def_jobs (job_name, mode, timeout_seconds, max_retries, max_parallel_processes, allocation_policy)
    VALUES (p_job_name, p_mode, p_timeout_seconds, p_max_retries, p_max_parallel_processes, p_allocation_policy)
    ON CONFLICT (job_name) DO UPDATE 
    SET mode = EXCLUDED.mode, timeout_seconds = EXCLUDED.timeout_seconds, max_retries = EXCLUDED.max_retries, max_parallel_processes = EXCLUDED.max_parallel_processes, allocation_policy = EXCLUDED.allocation_policy
    RETURNING job_id INTO v_job_id;

    DELETE FROM bg.def_tasks WHERE job_id = v_job_id; 

    FOREACH v_query_text IN ARRAY p_queries LOOP
        v_query_id := bg.register_query(v_query_text);
        INSERT INTO bg.def_tasks (job_id, query_id, execution_order) VALUES (v_job_id, v_query_id, v_order);
        v_order := v_order + 1;
    END LOOP;
    RETURN v_job_id;
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.create_job_definition(VARCHAR, bg.execution_mode, TEXT[], INT, INT, INT) FROM PUBLIC;

-- ============================================================================
-- FUNCTION: bg.start_job (The Internal Ignition Switch)
-- What is it?: Trigger that sets a job into motion.
-- What is it for?: Prepares the queue by setting all steps to PENDING, logs 
--                  the execution, and wakes up the Orchestrator to begin work.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.start_job(p_job_id INT) RETURNS INT AS $$
DECLARE v_run_id INT; v_mode bg.execution_mode;
BEGIN
    WITH new_run AS (
        INSERT INTO bg.run_jobs (job_id, status, started_at) VALUES (p_job_id, 'INITIALIZING', CLOCK_TIMESTAMP()) RETURNING run_id
    ), inserted_tasks AS (
        INSERT INTO bg.run_tasks (run_id, query_id, execution_order, status)
        SELECT nr.run_id, dt.query_id, dt.execution_order, 'PENDING' FROM bg.def_tasks dt CROSS JOIN new_run nr WHERE dt.job_id = p_job_id
    )
    SELECT run_id INTO v_run_id FROM new_run;

    PERFORM pg_background_launch(format('CALL bg.bg_job_orchestrator(%L)', v_run_id));
    
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.start_job(INT) FROM PUBLIC;

-- ============================================================================
-- FUNCTION: bg.launch_job_by_name (The Friendly Ignition Switch)
-- What is it?: Easy way to start an existing job.
-- What is it for?: Allows operators to launch jobs using string names 
--                  (e.g., 'MONTHLY_CLOSING') instead of remembering IDs.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.launch_job_by_name(p_job_name VARCHAR(100)) RETURNS INT AS $$
DECLARE v_job_id INT;
BEGIN
    SELECT job_id INTO v_job_id FROM bg.def_jobs WHERE job_name = p_job_name;
    IF v_job_id IS NULL THEN RAISE EXCEPTION 'Enterprise Job not found.'; END IF;
    RETURN bg.start_job(v_job_id);
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.launch_job_by_name(VARCHAR) FROM PUBLIC;

-- ============================================================================
-- FUNCTION: bg.launch_job_one_shot (All-in-One)
-- What is it?: Create and execute tool in a single step.
-- What is it for?: Combines template creation and ignition. Extremely useful 
--                  for fast testing or one-off tasks.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.launch_job_one_shot(
    p_job_name VARCHAR(100), p_mode bg.execution_mode, p_queries TEXT[], p_timeout_seconds INT DEFAULT 300, p_max_retries INT DEFAULT 0, p_max_parallel_processes INT DEFAULT 1,
    p_allocation_policy VARCHAR DEFAULT 'ADAPTIVE' -- 👈 NUEVO PARÁMETRO
) RETURNS INT AS $$
DECLARE v_job_id INT;
BEGIN
    v_job_id := bg.create_job_definition(p_job_name, p_mode, p_queries, p_timeout_seconds, p_max_retries, p_max_parallel_processes, p_allocation_policy);
    RETURN bg.start_job(v_job_id);
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.launch_job_one_shot(VARCHAR, bg.execution_mode, TEXT[], INT, INT, INT) FROM PUBLIC;

-- ============================================================================
-- FUNCTION: bg.replicate_query (The Cloner / Multiplier)
-- What is it?: Automatic query cloning utility.
-- What is it for?: Helps generate large arrays of the same query for stress 
--                  testing without needing to copy-paste 500 times.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.replicate_query(
    p_query TEXT, 
    p_times INT
) RETURNS TEXT[] AS $$
BEGIN
    IF p_times IS NULL OR p_times <= 0 THEN
        RAISE EXCEPTION 'Infrastructure Error: Replication count must be greater than zero (0).';
    END IF;

    -- Ultra-optimized in-memory function (Array Fill)
    RETURN array_fill(p_query, ARRAY[p_times]);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = bg, public, pg_temp; 

REVOKE EXECUTE ON FUNCTION bg.replicate_query(TEXT, INT) FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- PHASE 5: Pre-Sanitized Analytics Views
-- ----------------------------------------------------------------------------

-- ============================================================================
-- VIEW: bg.vw_corporate_progress_status (Visual Control Dashboard)
-- What is it?: The "traffic light" monitoring screen for managers.
-- What is it for?: Converts transactional logs into a dynamic progress bar 
--                  tracking queue advancement (Completed + Errors).
-- ============================================================================
CREATE OR REPLACE VIEW bg.vw_corporate_progress_status AS
WITH cte_metrics AS (
    SELECT rt.run_id, COUNT(*) AS total, COUNT(*) FILTER (WHERE rt.status = 'SUCCESS') AS completed, COUNT(*) FILTER (WHERE rt.status IN ('FAILED', 'KILLED')) AS errors, COUNT(*) FILTER (WHERE rt.status = 'PENDING') AS pending, COUNT(DISTINCT psa.pid) AS active_workers
    FROM bg.run_tasks rt
    LEFT JOIN pg_stat_activity psa ON rt.child_pid = psa.pid AND psa.backend_type = 'pg_background'
    GROUP BY rt.run_id
),
cte_clean AS (
    SELECT rj.run_id, rj.status, rj.started_at, rj.ended_at, rj.execution_notes, dj.job_name, dj.mode,
           COALESCE(m.total, 0) AS total, COALESCE(m.completed, 0) AS completed, COALESCE(m.errors, 0) AS errors, COALESCE(m.pending, 0) AS pending, COALESCE(m.active_workers, 0) AS active_workers
    FROM bg.run_jobs rj
    JOIN bg.def_jobs dj ON rj.job_id = dj.job_id
    LEFT JOIN cte_metrics m ON rj.run_id = m.run_id
)
SELECT 
    run_id AS "execution_id", job_name AS "job_name", mode AS "execution_mode",
    CASE 
        WHEN status = 'FAILED' AND execution_notes ILIKE '%ABORTED%' THEN '🛑 ABORTED (HARDWARE LIMIT)'
        WHEN mode IN ('SEQUENTIAL_STRICT', 'SEQUENTIAL_NORMAL') AND errors > 0 AND total = (completed + errors) THEN '❌ ABORTED (STRICT FAILURE)'
        WHEN total > 0 AND total = (completed + errors) AND errors > 0 THEN '⚠️ COMPLETED WITH ERRORS'
        WHEN total > 0 AND total = completed THEN '✅ COMPLETED'
        WHEN active_workers > 0 THEN '🔥 RUNNING (ENGINE ACTIVE)'
        WHEN status = 'FAILED' THEN '❌ CRITICAL ENGINE ERROR'
        ELSE '⏳ PENDING / INITIALIZING'
    END AS "actual_status",
    total AS "total_tasks", completed AS "completed", errors AS "errors", pending AS "pending", active_workers AS "active_workers",
    DATE_TRUNC('second', COALESCE(ended_at, CLOCK_TIMESTAMP()) - started_at) AS "duration",
    CASE WHEN total = 0 THEN '0%' ELSE ROUND(((completed + errors)::FLOAT / total::FLOAT) * 100)::TEXT || '%' END AS "progress_pct",
    '[' || REPEAT('█', CASE WHEN total = 0 THEN 0 ELSE ROUND(((completed + errors)::FLOAT / total::FLOAT) * 20)::INT END) || 
    REPEAT('░', 20 - CASE WHEN total = 0 THEN 0 ELSE ROUND(((completed + errors)::FLOAT / total::FLOAT) * 20)::INT END) || ']' AS "progress_bar",
    COALESCE(execution_notes, 'All systems nominal') AS "system_alerts" -- 👈 NUEVA COLUMNA PARA EL CLIENTE
FROM cte_clean
ORDER BY run_id DESC;

-- ============================================================================
-- VIEW: bg.vw_trazabilidad_forense (Pure Edition)
-- What is it?: Plain text audit log designed for developers and SysAdmins.
-- What is it for?: Measures net execution milliseconds and queue latencies 
--                  in flat formats compatible with ORMs and automation tools.
-- ============================================================================
CREATE OR REPLACE VIEW bg.vw_trazabilidad_forense AS
SELECT 
    rj.run_id,
    dj.job_name,
    dj.mode AS execution_mode,
    rt.execution_order,
    rt.status AS task_status,
    rt.attempt,
    COALESCE(rt.child_pid::TEXT, 'N/A') AS child_pid,
    rt.started_at AS task_started_at,
    DATE_TRUNC('ms', COALESCE(rt.ended_at, CLOCK_TIMESTAMP()) - rt.started_at) AS task_duration,
    DATE_TRUNC('ms', rt.started_at - rj.started_at) AS queue_latency,
    cq.query_hash,
    SUBSTRING(cq.query_text FROM 1 FOR 50) || CASE WHEN LENGTH(cq.query_text) > 50 THEN '...' ELSE '' END AS query_preview,
    COALESCE(rt.error_log, 'none') AS error_log
FROM bg.run_tasks rt
JOIN bg.run_jobs rj ON rt.run_id = rj.run_id
JOIN bg.def_jobs dj ON rj.job_id = dj.job_id
JOIN bg.cat_queries cq ON rt.query_id = cq.query_id
ORDER BY rj.run_id DESC, rt.execution_order ASC;

-- ----------------------------------------------------------------------------
-- PHASE 6: Decoupled Audit Triggers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bg.trg_archive_failed_attempt()
RETURNS TRIGGER AS $$
DECLARE
    v_query_text TEXT;
BEGIN
    IF NEW.status IN ('FAILED', 'KILLED') AND NEW.error_log IS NOT NULL THEN
        SELECT query_text INTO v_query_text FROM bg.cat_queries WHERE query_id = NEW.query_id;
        INSERT INTO bg.run_tasks_errors_history (
            run_task_id, run_id, execution_order, task_status, failed_attempt, query_text, error_log
        ) VALUES (
            NEW.run_task_id, NEW.run_id, NEW.execution_order, NEW.status, NEW.attempt, v_query_text, NEW.error_log
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

REVOKE EXECUTE ON FUNCTION bg.trg_archive_failed_attempt() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_tasks_forensic_monitor ON bg.run_tasks;
CREATE TRIGGER trg_tasks_forensic_monitor
BEFORE UPDATE ON bg.run_tasks
FOR EACH ROW
EXECUTE FUNCTION bg.trg_archive_failed_attempt();

-- ============================================================================
-- FUNCTION: bg.abort_job (The Emergency Brake / Kill Switch)
-- What it does: Finds an active Job, sends a kill signal (SIGINT) to the Parent 
--               and all live Children, and marks the remaining queue as KILLED.
-- ============================================================================
CREATE OR REPLACE FUNCTION bg.abort_job(p_job_name VARCHAR(500)) RETURNS TEXT AS $$
DECLARE
    v_job_id INT;
    v_run_id INT;
    v_parent_pid INT;
    v_child_pid INT;
    v_killed_children INT := 0;
    v_pending_aborted INT := 0;
BEGIN
    -- 1. Validate Job exists in catalog
    SELECT job_id INTO v_job_id FROM bg.def_jobs WHERE job_name = p_job_name;
    IF v_job_id IS NULL THEN
        RETURN '❌ ERROR: Enterprise Job not found: ' || p_job_name;
    END IF;

    -- 2. Find the ACTIVE execution for that Job
    SELECT run_id, monitor_pid INTO v_run_id, v_parent_pid 
    FROM bg.run_jobs 
    WHERE job_id = v_job_id AND status IN ('INITIALIZING', 'RUNNING')
    ORDER BY run_id DESC LIMIT 1;

    IF v_run_id IS NULL THEN
        RETURN '⚠️ WARNING: Job [' || p_job_name || '] has no active executions at this moment.';
    END IF;

    -- 3. ANNIHILATION PHASE A: Kill all live children
    FOR v_child_pid IN (SELECT child_pid FROM bg.run_tasks WHERE run_id = v_run_id AND status = 'RUNNING' AND child_pid IS NOT NULL)
    LOOP
        PERFORM pg_catalog.pg_cancel_backend(v_child_pid);
        v_killed_children := v_killed_children + 1;
    END LOOP;

    -- 4. ANNIHILATION PHASE B: Kill the Parent Orchestrator
    IF v_parent_pid IS NOT NULL THEN
        PERFORM pg_catalog.pg_cancel_backend(v_parent_pid);
    END IF;

    -- 5. CLEANUP PHASE: Destroy the task queue (Idempotency)
    WITH updated_pending AS (
        UPDATE bg.run_tasks 
        SET status = 'KILLED', error_log = 'manually_aborted' 
        WHERE run_id = v_run_id AND status = 'PENDING' 
        RETURNING 1
    ) SELECT COUNT(*) INTO v_pending_aborted FROM updated_pending;

    -- Mark running children as killed
    UPDATE bg.run_tasks 
    SET status = 'KILLED', ended_at = pg_catalog.clock_timestamp(), error_log = 'manually_aborted_sigint' 
    WHERE run_id = v_run_id AND status = 'RUNNING';

    -- Mark Job header as failed via human intervention
    UPDATE bg.run_jobs 
    SET status = 'FAILED', ended_at = pg_catalog.clock_timestamp() 
    WHERE run_id = v_run_id;

    RETURN pg_catalog.format(
        '🛑 PANIC BUTTON TRIGGERED: Job [%s] aborted. Killed workers: %s. Destroyed pending tasks: %s.', 
        p_job_name, v_killed_children, v_pending_aborted
    );
END;
$$ LANGUAGE plpgsql SET search_path = bg, public, pg_temp;

-- Restrictive security: No external user should be able to shutdown the engine
REVOKE EXECUTE ON FUNCTION bg.abort_job(VARCHAR) FROM PUBLIC;

COMMIT;
