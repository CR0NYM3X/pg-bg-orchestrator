 
# 🌟 pg-bg-orchestrator (AROF)
**Native, developer-friendly background task orchestration for PostgreSQL.** <br>
**(AROF) Asynchronous Resilient Orchestration Framework.**

## 🤔 What is it and what is it for?

Sometimes you need to execute heavy queries, massive database maintenance, or complex data migrations. If you run them the traditional way, your client connection hangs ("freezes"), preventing you from doing anything else and potentially blocking other users.

That is where **`pg-bg-orchestrator`** comes in. As its name suggests, it is an **Orchestrator**. 

**What is an Orchestrator?**
Think of it as a conductor for an orchestra or a traffic cop for your database. It does not just blindly push tasks to the background; it takes full, intelligent control:
* It decides **when** and in what **strict order** steps are executed.
* It controls **how many** tasks can run simultaneously without suffocating your server's memory.
* It makes critical decisions if something goes wrong: Should it retry the task? Should it ignore it and move on? Or should it hit the panic button and abort the entire job?

It performs a coordination job very similar to massive external message queues or workflow tools (like Airflow, Celery, or RabbitMQ), but **focused exclusively on database tasks**. This saves you the nightmare of installing, configuring, and maintaining extra servers if all your business logic already lives inside PostgreSQL.

## 🏆 Special Thanks
Before getting started, full credit and a huge thank you to **Robert Haas** and **Vibhor Kumar**, the brilliant creator of the `pg_background` extension. Without his pioneering work allowing native asynchronous processes in PostgreSQL, this orchestrator quite simply would not exist. Thank you, Robert!

## 📋 Prerequisites
To run this framework in your database, you need:
* PostgreSQL 10 or higher.
* The `pg_background` extension installed on your server.

---

## 🚦 Execution Modes (How do we process the queue?)

You can tell the orchestrator exactly how you want it to consume your task list. We offer 4 distinct flavors:

* 🛤️ **`SEQUENTIAL_STRICT` (Strict Step-by-Step)**
  * **How it executes:** It picks up Task 1 -> waits for the child process to finish before opening another one. If it returns a success, it opens the next one; otherwise, it immediately aborts all remaining tasks left in the list.

* 🚶 **`SEQUENTIAL_NORMAL` (Tolerant Step-by-Step)**
  * **How it executes:** It picks up Task 1 -> waits for the process to finish, but *it does not care if it errored out or succeeded*. It will relentlessly execute the next process in the list as soon as the previous one finishes.

* 🌊 **`CONCURRENT_ORDERED` (Ordered Burst with Safety Valve)**
  * **How it executes:** It picks up the first task in the list and *does not wait for it to finish*. Almost instantly, it executes the next task, and the next, and the next, until it hits the concurrency limit you specified in `p_max_parallel_processes`. Once it reaches that cap, it begins waiting for any active process to finish before spawning the next one, constantly keeping your specified limit maxed out.

* 🎲 **`RANDOM` (Shuffled Burst / Lock Avoidance)**
  * **How it executes:** It picks up tasks completely at random (e.g., Task 1, then Task 5, Task 2, Task 8). It does not follow any numerical order, but it strictly respects your `p_max_parallel_processes` safety limit. Once it fills up your parallel capacity, it waits for an slot to open up and fires another random process. This is excellent for preventing your storage disk from bottlenecking when writing to sequential rows!

---

## ⚠️ Critical Infrastructure Note (Server Process Limits)

Even though this framework gives you the freedom to configure your concurrent thread limit using the `p_max_parallel_processes` parameter, **the AROF engine cannot perform magic above your server's physical limits**. 

All asynchronous capabilities in this tool rely on the `pg_background` extension, which consumes slots from a native PostgreSQL configuration parameter called **`max_worker_processes`** (defined inside your `postgresql.conf` file).

**What does this mean in real-world operations?**
* If you configure a Job with `p_max_parallel_processes => 20`, but your PostgreSQL server has a global configuration capping `max_worker_processes = 8`, the orchestrator will hit a brick wall. It will try to spawn the 9th concurrent task, but the operating system will deny the slot, triggering a native PostgreSQL error: *"background worker slot not available"*.
* **Golden Rule:** Before running massive concurrent stress tests, coordinate with your DBA to review your server capacity. Make sure that the `max_worker_processes` value in your PostgreSQL configuration is **always greater** than the maximum number of parallel processes you plan to run across your active async jobs. Protect your hardware!

---

### 🛠️ A Real-World Case Study: The Daily Life of a DBA

Imagine it is 2:00 AM and you need to perform deep maintenance on a gigantic table. You need these steps to execute in a super-strict order, because it makes absolutely no sense to waste server CPU running a `VACUUM` or a `REINDEX` if your initial `DELETE` script failed.

**The Solution using `SEQUENTIAL_STRICT` mode:**

```sql
SELECT bg.launch_job_one_shot(
    'MANTENIMIENTO_TABLA_GIGANTE', 
    'SEQUENTIAL_STRICT', 
    ARRAY[
        'DELETE FROM tabla_gigante WHERE fecha < ''2020-01-01'';',
        'VACUUM tabla_gigante;',
        'REINDEX TABLE tabla_gigante;',
        'ANALYZE tabla_gigante;'
    ]
);

```

**What will happen internally on your server?**
The Orchestrator will take this array and create a single-lane execution pipeline. It will launch the first task (the `DELETE`) and patiently sleep in the background.

* If the `DELETE` completes successfully, the Orchestrator marks it with a checkmark and automatically fires the second task (the `VACUUM`), proceeding smoothly down the line.
* If the `DELETE` fails (for example, because the table was locked by a rogue transaction early in the morning), the "Strict" rule triggers instantly: the Orchestrator aborts the entire job right there, marks the remaining 3 tasks as cancelled, and gracefully stops without wasting any more CPU.

**What is expected from this process?**
Operational peace of mind. The DBA can go to sleep knowing that upon checking the database the next morning, only two outcomes are possible:

1. A dashboard marked as **`COMPLETED`**, guaranteeing all 4 steps executed perfectly in sequence and the table is fully optimized.
2. A dashboard marked as **`FAILED`**, highlighting exactly at which step the engine stopped alongside the raw, original PostgreSQL error message. Your database is completely safe from half-baked, broken maintenance cycles.

---

### 📊 Ecosystem Comparative Analysis

To understand where `pg-bg-orchestrator` fits best, it helps to see how it solves problems compared to other solutions on the market. It does not replace an enterprise multi-cloud workflow suite, but it shines when your workload is purely data-centric and resides entirely inside PostgreSQL.

| Operational Capability | 💎 pg-bg-orchestrator | `pg_cron` (Extension) | `pgmq` / SQL Queues | External (Airflow / Celery) |
| --- | --- | --- | --- | --- |
| **Primary Trigger** | On-Demand (Events/Instant) | Clock-Based (Fixed Schedules) | On-Demand | Events, Cron, and Web APIs |
| **Infrastructure Overhead** | **Zero** (100% Native SQL) | **Zero** (Native) | Requires external scripts to read queues | **High** (Python nodes, Redis, DevOps) |
| **Concurrency Pool Limits** | Yes (Configurable strict valve) | No | No (Depends on external consumer) | Yes (Highly granular tuning) |
| **Time Controls (Timeouts)** | Native process-level auto-kill | No | No | Yes (Managed by external workers) |
| **Automatic Retries** | Integrated per task | No | Integrated | Integrated |
| **Out-of-DB Integration** | Limited (Requires `dblink`/`fdw`) | Limited | Excellent (If your script supports it) | **Native** (Webhooks, Clouds, Servers) |

---

## 📖 Meet the Objects (API)

Don't worry, the system uses very simple tables and objects to keep track of everything under the hood:

**🗄️ Tables (Where data is stored):**

* `bg.cat_queries`: Stores unique SQL scripts (deduplicated via native MD5 hashes).
* `bg.def_jobs`: Stores the configuration templates for your jobs (limits, timeouts, and max retries).
* `bg.def_tasks`: This is your "recipe book"; it maps which steps belong to which Job.
* `bg.run_jobs`: High-level execution logs tracking when a general Job started and ended.
* `bg.run_tasks`: The live queue! Tracks the step-by-step real-time status of every task and captures failure logs.
* `bg.run_tasks_errors_history`: **[NEW]** The immutable forensic black box. It archives the task status, failed attempt, and the exact query text of any transaction before it gets cleared for a retry cycle.

**👁️ Views (For easy monitoring):**

* `bg.vw_corporate_progress_status`: A highly readable, management-ready dashboard displaying progress percentage (%), active background workers, and automated progress bars.
* `bg.vw_trazabilidad_forense`: **[NEW]** Pure textual view designed for DBAs, ORMs, and automation tooling. It measures net task duration, queue latency, and execution summaries with ms precision.

**⚙️ Functions & Procedures (Your control room):**

* `bg.create_job_definition()`: Creates or updates a reusable Job template.
* `bg.start_job()`: Pulls the trigger on a pre-defined Job template to wake up the orchestrator.
* `bg.launch_job_one_shot()`: The ultimate wrapper! Creates and executes a Job simultaneously in a single command line.
* `bg.replicate_query()`: A utility function that clones an SQL query $X$ amount of times in memory—perfect for preparing high-throughput stress tests.
* `bg.abort_job()`: **[NEW]** The global emergency brake (Kill Switch). It intercepts an active job, sends a SIGINT signal to cancel the parent orchestrator and all live workers at the OS level, and destroys the remaining queue instantly.

 
---
---

## 🚀 Changelog & Updates (Edition: Diamond)

### 🛡️ Security & Concurrency (Zero-Day Mitigations)
* **Phantom Abort Race Condition Fixed:** Mitigated a critical vulnerability vector where Operating System latency caused the duplication of financial tasks. An **Optimistic Locking** shield (`AND status = 'RUNNING'`) was implemented in the Orchestrator, guaranteeing mathematical idempotency and protecting successful transactions against blind overwrites.
* **CPU Leak Optimization:** Strict optimization in the retry validation loop (`v_failed_list`). The Orchestrator now filters in-memory only the failed tasks that still have attempts available (`attempt <= v_max_retries`), eliminating CPU cycle leaks caused by dead tasks.

### ⚙️ Infrastructure & Resilience (Hardware Throttling)
* **Hardware Throttling Valve:** The Orchestrator is now tolerant to physical server throttling. If the native PostgreSQL limit (`max_worker_processes`) is reached, the engine no longer collapses or panics. The system absorbs the impact asynchronously, pauses launches, and dynamically waits for resources to be freed on the host.
* **Schema Drift Resolution:** Data dictionary standardization. The `execution_notes` audit column was moved to the correct transactional table (`bg.run_jobs`), ensuring the perfect compilation of corporate forensic views.

### 🎛️ New Features (Resource Allocation Policies)
Introduced the API-level control parameter `allocation_policy` in `launch_job_one_shot` and `create_job_definition`, granting the user total governance over hardware saturation:
* **`ADAPTIVE` Mode (Default):** Faced with a lack of hardware resources, the job enters survival mode. The orchestrator pauses the launch, alerts the control panel (`⚠️ ADAPTIVE: Running in degraded mode`), and hoards slots as they become available.
* **`STRICT` Mode (Fail-Fast):** Designed for critical SLAs. If the orchestrator does not obtain the requested physical resources at the exact moment of launch, it aborts immediately, annihilates the workers in flight, and notifies the collapse (`🛑 ABORTED: Hardware slot limit reached`), preventing slow executions and disk blocking.

### 📐 Architectural Guidelines (Atomic Transactions)
* **Official Rejection of the 2PC Pattern (`PREPARE TRANSACTION`):** For cluster security and *XID Wraparound* prevention, the orchestration of tasks with strict atomicity ("All or Nothing") does not use prepared transactions.
* **Best Practice:** It is now standardized that dependent atomic operations must be semantically grouped into a single worker using native transactional blocks (`DO $$BEGIN ... EXCEPTION ... END$$;`) within the Orchestrator's queue.
