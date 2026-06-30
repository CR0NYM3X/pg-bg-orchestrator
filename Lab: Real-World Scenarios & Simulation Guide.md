 
 
# 🧪 DIAMOND LABORATORY: REAL-WORLD OPERATIONS & CRISIS SIMULATOR

Dear team, this laboratory demonstrates the raw power of the `bg` AROF framework operating on real-world data scenarios. Please execute each block in order.

## 🛠️ STEP 0: Environment Setup (Production Sandbox)

We are going to create tables that simulate your company's reality: bank accounts, DBA cleanup logs, and IoT sensor records.

```sql

\c postgres
drop database bk;
create database bk;
\c bk


-- 1. Create the isolated schema
CREATE SCHEMA IF NOT EXISTS bg_lab;

-- 2. Table for the Backend Developer (Finance)
CREATE TABLE IF NOT EXISTS bg_lab.bank_accounts (
    account_id SERIAL PRIMARY KEY,
    client_name VARCHAR(50),
    balance NUMERIC(15,2)
);

-- 3. Table for the Senior ETL Engineer (Massive Loads)
CREATE TABLE IF NOT EXISTS bg_lab.etl_sales_staging (
    id SERIAL PRIMARY KEY,
    region VARCHAR(50),
    amount NUMERIC(10,2),
    is_processed BOOLEAN DEFAULT FALSE
);

-- 4. Table for QA / Stress Testing (IoT)
CREATE TABLE IF NOT EXISTS bg_lab.iot_sensor_logs (
    log_id SERIAL PRIMARY KEY,
    sensor_id INT,
    reading NUMERIC(5,2),
    recorded_at TIMESTAMP DEFAULT CLOCK_TIMESTAMP()
);

-- 5. Prepare initial baseline data
TRUNCATE TABLE bg_lab.bank_accounts, bg_lab.etl_sales_staging, bg_lab.iot_sensor_logs RESTART IDENTITY CASCADE;

INSERT INTO bg_lab.bank_accounts (client_name, balance) 
VALUES 
    ('Company A', 10000.00), 
    ('Supplier B', 0.00),
    ('Alpha Corporate LLC', 1500000.00),
    ('Mary Johnson', 3450.50),
    ('John Smith', 125.00),
    ('Tech Solutions Inc', 89400.75),
    ('Victoria Ruiz', 45000.20);

INSERT INTO bg_lab.etl_sales_staging (region, amount, is_processed) 
VALUES
    ('North', 12500.00, FALSE),
    ('South', 8400.50, FALSE),
    ('Central', 450.25, TRUE),
    ('West', 32000.00, FALSE),
    ('East', 1500.99, TRUE);

INSERT INTO bg_lab.iot_sensor_logs (sensor_id, reading) 
VALUES
    (101, 24.50),
    (102, 18.25),
    (101, 24.65), -- Simulating a second read from the same sensor
    (103, 89.10),
    (104, 12.00);

SELECT * FROM bg_lab.bank_accounts;
SELECT * FROM bg_lab.etl_sales_staging;
SELECT * FROM bg_lab.iot_sensor_logs;

```

---

## 🏛️ SCENARIO 1: The Financial Shield (Role: Backend Developer)

* **Mode:** `SEQUENTIAL_STRICT` (One by one. If one fails, abort all subsequent activities).
* **The Real Case:** We need to transfer $5,000 from Company A to Supplier B. The system subtracts the money from Company A (Step 1). But suddenly, the network fails (Step 2).
* **What is it for?:** Prevents data corruption. If the system wasn't strict, Step 3 would execute and give Supplier B a free $5,000 without completing the validation.

**Execution:**

```sql
SELECT bg.launch_job_one_shot(
    '01_BANK_TRANSFER', 
    'SEQUENTIAL_STRICT', 
    ARRAY[
        'UPDATE bg_lab.bank_accounts SET balance = balance - 5000 WHERE client_name = ''Company A'';',
        'SELECT 1 / 0; -- SIMULATED CRITICAL NETWORK FAILURE',
        'UPDATE bg_lab.bank_accounts SET balance = balance + 5000 WHERE client_name = ''Supplier B'';'
    ]
);

```

**🔍 How to Validate (Audit):**

1. **Orchestration Audit:** `SELECT * FROM bg.vw_corporate_progress_status WHERE job_name = '01_BANK_TRANSFER';`
*(You will see Status `❌ ABORTED (STRICT FAILURE)`. Completed: 1, Errors: 1, Pending: 1. The engine stopped dead in its tracks).*
2. **Business Audit:** `SELECT * FROM bg_lab.bank_accounts;`
*(You will see Supplier B still has $0.00. Money wasn't created out of thin air. The database is safe).*

---

## 🧹 SCENARIO 2: Operational Continuity (Role: DBA)

* **Mode:** `SEQUENTIAL_NORMAL` (One by one. If one fails, log it and move to the next).
* **The Real Case:** At 3:00 AM, the DBA schedules a partition cleanup for 3 different months of historical logs. February's table was accidentally deleted yesterday. If the script were strict, the entire maintenance routine would abort and March would not be cleaned.
* **What is it for?:** For maintenance or processes that are not interdependent. It absorbs the error, isolates the failure, and forces the engine to finish the remaining work so it doesn't affect tomorrow's operations.

**Execution:**

```sql
SELECT bg.launch_job_one_shot(
    '02_DBA_MAINTENANCE', 
    'SEQUENTIAL_NORMAL', 
    ARRAY[
        'DELETE FROM bg_lab.iot_sensor_logs WHERE log_id <= 3;',
        'DROP TABLE history_table_february; -- ERROR: TABLE DOES NOT EXIST',
        'DELETE FROM bg_lab.etl_sales_staging WHERE is_processed = false;'
    ]
);

```

**🔍 How to Validate (Audit):**

1. **Orchestration Audit:** Check the dashboard.
*(You will see `⚠️ COMPLETED WITH ERRORS`. Completed: 2, Errors: 1. Total transparency. The orchestrator waited for the IoT cleanup to finish, tried to drop the table and failed, and then sequentially cleaned the ETL staging).*

```sql
SELECT * FROM bg.vw_corporate_progress_status WHERE job_name = '02_DBA_MAINTENANCE' ORDER BY execution_id DESC LIMIT 2;

SELECT * FROM bg_lab.bank_accounts;
SELECT * FROM bg_lab.etl_sales_staging;
SELECT * FROM bg_lab.iot_sensor_logs;

```

---

## ⚡ SCENARIO 3: Performance Burst (Role: Senior ETL Engineer)

* **Mode:** `CONCURRENT_ORDERED` (Fires multiple processes in parallel following the queue order).
* **The Real Case:** Month-end closing. You must consolidate sales calculations for 4 massive regions (North, South, East, West). Doing it one by one takes too long.
* **What is it for?:** Injects the entire workload directly into the server processors (CPU) so they resolve everything in parallel, reducing execution time to a fraction of the original.

**Execution (Simulating heavy calculations of 4 seconds each):**

```sql
SELECT bg.launch_job_one_shot(
    '03_REGIONAL_ETL_CLOSING', 
    'CONCURRENT_ORDERED', 
    ARRAY[
        'SELECT pg_sleep(4); -- Processing North Region',
        'SELECT pg_sleep(4); -- Processing South Region',
        'SELECT pg_sleep(4); -- Processing East Region',
        'SELECT pg_sleep(4); -- Processing West Region'
    ],
    p_max_parallel_processes => 4 -- ALLOW BURST OF 4
);

```

**🔍 How to Validate (Live Visual Audit):**

* Run the status view multiple times rapidly during the first 4 seconds:
*(You will observe `active_workers: 4`. In exactly 4 seconds of real clock time, all 4 tasks will mark success simultaneously. Parallelism is absolute).*

---

## 🚦 SCENARIO 4: The Traffic Controller (Role: Data Engineer)

* **Mode:** `RANDOM` with `p_max_parallel_processes` limit.
* **The Real Case:** The system must import 6 gigantic CSV files. If the engineer throws them all in parallel without limits, the server will consume 100% of RAM and crash the company's sales system.
* **What is it for?:** You define a "safety valve". If the limit is 2, the orchestrator picks 2 files, processes them, and keeps the other 4 asleep. As one finishes, it injects the next one without choking the RAM.

**Execution:**

```sql
SELECT bg.launch_job_one_shot(
    '04_CONTROLLED_MASSIVE_LOAD', 
    'RANDOM', 
    ARRAY[
        'SELECT pg_sleep(3);', 'SELECT pg_sleep(3);', 'SELECT pg_sleep(3);', 
        'SELECT pg_sleep(3);', 'SELECT pg_sleep(3);', 'SELECT pg_sleep(3);'
    ],
    p_max_parallel_processes => 2 -- SAFETY VALVE
);

```

**🔍 How to Validate (Funnel Audit):**

* Run the dashboard every second:
*(You will empirically verify that `active_workers` never exceeds 2, and `pending` will decrease rhythmically. The entire process will take 9 real seconds (3 blocks of 3 seconds)).*

---

## 🔪 SCENARIO 5: The Unyielding Executioner (Role: DBA)

* **The Real Case:** A junior analyst executes a poorly designed report (an infinite Cartesian join) that drains the CPU. Sales are frozen and nobody knows what is happening.
* **What is it for?:** The framework trusts no one. If you set a lifespan limit (timeout) of 2 seconds, the Parent Orchestrator kills the rogue process at the Operating System level, freeing the CPU automatically without human intervention.

**Execution:**

```sql
SELECT bg.launch_job_one_shot(
    '05_JUNIOR_ANALYST_REPORT', 
    'SEQUENTIAL_NORMAL', 
    ARRAY[
        'WITH RECURSIVE t(n) AS (VALUES (1) UNION ALL SELECT n+1 FROM t) SELECT count(*) FROM t; -- Real infinite loop'
    ],
    p_timeout_seconds => 2, -- KILL IF EXCEEDS 2 SECONDS
    p_max_retries => 0
);

```

**🔍 How to Validate (Forensic Audit):**

* Wait 3 seconds and check the task queue:

```sql
SELECT status, error_log FROM bg.run_tasks ORDER BY run_id DESC LIMIT 1;

```

*(You will see Status `FAILED` and the exact reason: "Killed by Parent (Strict Timeout)". The analyst was stopped cold).*

---

## 💥 SCENARIO 6: Massive Ingestion and Stress Testing (Role: Automated QA)

* **The Real Case:** Tomorrow is the "Night Sale" campaign. The QA team needs to simulate 100 sensors or clients inserting data at the exact same time to see if the table indexes can withstand the pressure.
* **What is it for?:** The `bg.replicate_query()` function clones a query instantly in RAM. It prevents you from writing 100 lines of code and eliminates copy-paste human errors.

**Execution (Simulating 100 simultaneous inserts in a single line):**

```sql
SELECT bg.launch_job_one_shot(
    '06_IOT_STRESS_TEST', 
    'CONCURRENT_ORDERED', 
    bg.replicate_query(
        'INSERT INTO bg_lab.iot_sensor_logs (sensor_id, reading) VALUES (FLOOR(RANDOM()*1000), RANDOM()*100);', 
        100 -- Number of atomic clones
    ),
    p_timeout_seconds => 60,
    p_max_parallel_processes => 10, -- 10 concurrent connections to avoid OS saturation
    p_max_retries => 0
);

```

**🔍 How to Validate (Stress Audit):**

1. **The Dashboard:** You will see Job `06_IOT_STRESS_TEST` completed in milliseconds with `total_tasks: 100`.
2. **The Real Data:**

```sql
SELECT COUNT(*) AS total_lecturas FROM bg_lab.iot_sensor_logs;

```

*(The count will say exactly `100`. You just injected and orchestrated a massive stress test without cluttering your SQL editor).*

---

## 📜 SCENARIO 7: Historical Immutability (The John and Robert Case)

* **The Real Crisis:** John creates a Job template. Robert runs it in January. In February, John updates the Job and deletes 2 steps. When querying January's reports, the database crashes due to "Foreign Key" errors or shows falsified historical data (modified by February's changes).
* **What is this mode for?:** The framework uses **Decoupled Snapshots**. Every execution is a photograph frozen in time. You can rewrite and alter the templates (`def_jobs`) 100 times, and the historical execution logs will never be corrupted.

**Execution:**

```sql
-- 1. Template is defined (Day 1)
SELECT bg.create_job_definition('07_CASH_CLOSING', 'SEQUENTIAL_NORMAL', ARRAY['SELECT pg_sleep(1);']);

-- 2. Job is launched (Saved in history with 1 task)
SELECT bg.launch_job_by_name('07_CASH_CLOSING');

-- 3. Template is REWRITTEN atomically adding more load (Day 2)
SELECT bg.create_job_definition('07_CASH_CLOSING', 'SEQUENTIAL_NORMAL', ARRAY['SELECT pg_sleep(1);', 'SELECT pg_sleep(1);', 'SELECT pg_sleep(1);']);

-- 4. New version is launched
SELECT bg.launch_job_by_name('07_CASH_CLOSING');

```

**🔍 How to Validate (Audit):**

* Check the dashboard filtering by that job name. You will see two records with the exact same Job Name, but the newest one shows `total_tasks: 3` and right below it in history, the intact old record shows `total_tasks: 1`.

---

## 🏛️ SCENARIO 8: The Lifesaver Against Micro-Outages (Role: Integration Engineer)

* **The Real Crisis:** Every day at 6:00 AM, your database connects to the Central Bank's server via a `dblink` (or Foreign Data Wrapper) to extract the dollar exchange rate. The problem is the bank's server is unstable; it sometimes has network "micro-outages" that last a couple of seconds. If your system tries only once and fails, the entire day's financial reports will output zeros.
* **What is `p_max_retries` for?:** It tells the Parent Orchestrator: *"If the child process fails due to a network error, a table lock, or a timeout, do not kill it permanently. Clean it up, return it to the pending queue, and give it another chance (up to N times) before giving up."*

**Execution (Simulating a network failure using division by zero):**
In this test, we will tell the orchestrator it has the right to **3 retries**. Because the error is mathematical (`1/0`), it will inevitably fail every time, but it will help us audit how the system exhausts all its chances before surrendering.

```sql
SELECT bg.launch_job_one_shot(
    '08_EXCHANGE_RATE_SYNC', 
    'SEQUENTIAL_NORMAL', 
    ARRAY[
        'SELECT 1 / 0; -- Simulating temporary Bank server crash'
    ],
    p_timeout_seconds => 5,
    p_max_retries => 3 -- 🚀 THE LIFESAVER: 1 original attempt + 3 retries
);

```

**🔍 How to Validate (Persistence Audit):**

To see the retry magic in action, wait a couple of seconds and query the detailed task queue. We want to see the **`attempt`** column:

```sql
SELECT 
    run_task_id, 
    status, 
    attempt AS "Current Attempt", 
    error_log 
FROM bg.run_tasks 
ORDER BY run_id DESC LIMIT 1;

```

**📊 The Result you will see on your screen:**

* **Current Attempt:** `4` *(The 1 original attempt + the 3 retries you authorized).*
* **Status:** `FAILED` *(Because it exhausted all its lives).*
* **Error Log:** `division by zero`

**🕵️ Forensic Black Box Audit:**
Let's look into the Forensic History table to prove the orchestrator saved the evidence of the previous 3 failed attempts before wiping them for the next try:

```sql
SELECT task_status, failed_attempt, error_log 
FROM bg.run_tasks_errors_history 
ORDER BY history_id DESC LIMIT 3;

```

*(You will see the detailed log of attempt 1, 2, and 3 safely archived for developers to audit later).*

### 💡 Why is this pure gold in Production?

If we were in a real-world scenario, let's say on **Attempt 1** and **Attempt 2** the bank's network was down. The error would be logged in the forensic box, but the task would revert to `PENDING`. If on **Attempt 3** the bank's network restores, the task would switch to `SUCCESS` and the entire Job would be saved.

The DBA did not have to wake up at 6:00 AM to restart the process manually; **the framework had the intelligence to auto-recover.**

