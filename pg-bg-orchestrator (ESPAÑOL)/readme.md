# 🌟 pg-bg-orchestrator (FOAR)
**Orquestación de tareas en segundo plano, nativa y amigable para PostgreSQL.** <br>
**(FOAR) Framework de Orquestación Asíncrona Resiliente.**

## 🤔 ¿Qué es y para qué sirve?

A veces necesitas ejecutar consultas pesadas, mantenimientos masivos o migraciones de datos. Si lo haces de forma tradicional, tu conexión se queda "pensando" (congelada) y te impide seguir trabajando o bloquea a otros usuarios. 

Ahí es donde entra **`pg-bg-orchestrator`**. Como su nombre lo indica, es un **Orquestador**. 

**¿Qué es un Orquestador?**
Piensa en él como el director de una orquesta o un policía de tránsito para tu base de datos. No se limita simplemente a mandar las tareas al "fondo" (background), sino que toma el control total y de forma inteligente:
* Decide **cuándo** y en qué **orden estricto** se ejecutan los pasos.
* Controla **cuántas** tareas pueden correr al mismo tiempo.
* Toma decisiones críticas si algo sale mal: ¿Debe reintentar la tarea? ¿Debe ignorarla y seguir? ¿O debe accionar un botón de pánico y abortar todo?

Hace un trabajo de coordinación muy similar al de herramientas de colas externas gigantes (como Airflow, Celery o RabbitMQ), pero **enfocado exclusivamente en bases de datos**, ahorrándote la pesadilla de instalar y mantener servidores extra si toda tu lógica de negocio ya vive dentro de PostgreSQL.

## 🏆 Agradecimientos Especiales
Antes de empezar, todo el crédito y un enorme agradecimiento a **Robert Haas**, el brillante creador de la extensión `pg_background`. Sin su trabajo pionero para permitir procesos asíncronos nativos en PostgreSQL, este orquestador simplemente no existiría. ¡Gracias, Robert!

## 📋 Requisitos Previos
Para que este framework funcione en tu base de datos, necesitas:
* PostgreSQL 10 o superior.
* La extensión `pg_background` instalada en tu servidor.

 
---

## 🚦 Modos de Ejecución (¿Cómo procesamos la cola?)

Puedes decirle al orquestador cómo quieres que consuma tu lista de tareas. Tenemos 4 sabores distintos:

* 🛤️ **`SEQUENTIAL_STRICT` (Paso a paso estricto)**
  * **Cómo ejecuta:** Toma la tarea 1 -> espera que termine el proceso hijo antes de abrir otro. Si retorna un éxito, abre el siguiente; de lo contrario, aborta todos los demás procesos que estaban en la lista.

* 🚶 **`SEQUENTIAL_NORMAL` (Paso a paso tolerante)**
  * **Cómo ejecuta:** Toma la tarea 1 -> espera a que termine el proceso, pero *no le importa si marcó error o fue exitoso*. Él ejecutará el siguiente proceso de la lista una vez que haya terminado el anterior.

* 🌊 **`CONCURRENT_ORDERED` (Ráfaga ordenada con límite)**
  * **Cómo ejecuta:** Toma el primero de la lista y *no espera a que termine*. Casi al instante ejecuta la siguiente tarea, y la siguiente, y la siguiente, hasta cumplir con el límite que le pusiste en `p_max_parallel_processes`. Una vez que llega al máximo de procesos permitidos, ahí empieza a esperar a que finalice uno para abrir otro, tratando de mantener siempre tu límite al tope.

* 🎲 **`RANDOM` (Ráfaga aleatoria anti-bloqueos)**
  * **Cómo ejecuta:** De manera aleatoria (ej. primero la tarea 1, luego la 5, la 2, la 8). Este no sigue un orden, pero igual respeta tu límite `p_max_parallel_processes`. Una vez que cumple con ese límite, espera a que finalice uno y abre otro proceso. ¡Excelente para evitar que el disco duro se sature escribiendo en el mismo lugar!

---


## ⚠️ Nota Crítica de Infraestructura (Límite de Procesos del Servidor)

Aunque este framework te da la libertad de configurar el límite de hilos concurrentes mediante el parámetro `p_max_parallel_processes`, **el motor FOAR no puede hacer magia por encima de las restricciones de tu servidor**. 

Toda la asincronía de esta herramienta se apoya sobre la extensión `pg_background`, la cual consume ranuras o "slots" de un parámetro nativo de PostgreSQL llamado **`max_worker_processes`** (definido en tu archivo `postgresql.conf`).

**¿Qué significa esto en la vida real?**
* Si en tu base de datos configuras un Job con `p_max_parallel_processes => 20`, pero tu servidor PostgreSQL tiene un límite general de `max_worker_processes = 8`, el orquestador se estampará contra una pared física. Intentará abrir el proceso 9, pero el sistema operativo le negará el espacio, provocando un error de tipo *"background worker slot not available"*.
* **Recomendación de oro:** Antes de realizar pruebas de estrés masivas, coordina con tu DBA para revisar la capacidad de tu servidor y asegúrate de que el valor de `max_worker_processes` en la configuración de PostgreSQL sea **siempre mayor** al número de procesos máximos que planeas ejecutar en tus Jobs asíncronos. ¡Cuida tu hardware!

### 🛠️ Un Caso de Uso Real: El día a día de un DBA

Imagina que son las 2:00 AM y necesitas hacer una limpieza profunda de una tabla gigantesca. Quieres que los pasos se ejecuten en un orden súper estricto, porque no tiene sentido gastar recursos del servidor haciendo un `VACUUM` o un `REINDEX` si el borrado de datos falló.

**La Solución usando el modo `SEQUENTIAL_STRICT`:**

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

**¿Qué va a pasar internamente en el servidor?**
El Orquestador tomará esta lista y creará un carril único de ejecución. Lanzará la primera tarea (el `DELETE`) y se pondrá a esperar pacientemente en segundo plano.

* Si el `DELETE` termina con éxito, el Orquestador lo marcará con una palomita y lanzará automáticamente la segunda tarea (el `VACUUM`), y así sucesivamente respetando el orden.
* Si el `DELETE` falla (por ejemplo, porque la tabla estaba bloqueada por otro proceso en la madrugada), la regla "Estricta" entra en acción: el Orquestador abortará el trabajo completo, marcará las siguientes 3 tareas como canceladas y no gastará CPU intentando ejecutarlas.

**¿Qué se espera de este proceso?**
Tranquilidad operativa. El DBA puede irse a dormir sabiendo que, al revisar la base de datos a la mañana siguiente, solo encontrará dos escenarios posibles:

1. Un tablero en **`COMPLETED`**, garantizando que los 4 pasos se ejecutaron en el orden correcto y la tabla está optimizada.
2. Un tablero en **`FAILED`**, donde verá exactamente en qué paso se detuvo el motor junto con el mensaje de error original de PostgreSQL. La base de datos estará a salvo de mantenimientos ejecutados a medias.



 
---

### 📊 Análisis Comparativo del Ecosistema

Para entender dónde encaja `pg-bg-orchestrator`, es importante ver qué resuelve frente a otras soluciones del mercado. No reemplaza a un ecosistema multinube, pero brilla cuando tu carga de trabajo es puramente transaccional y reside en PostgreSQL.

| Capacidad Operativa | 💎 pg-bg-orchestrator | `pg_cron` (Extensión) | `pgmq` / Colas SQL | Externas (Airflow / Celery) |
| --- | --- | --- | --- | --- |
| **Disparador Principal** | Bajo demanda (Eventos/Instantáneo) | Basado en reloj (Horarios fijos) | Bajo demanda | Eventos, Horarios y APIs |
| **Infraestructura Requerida** | **Cero** (100% Nativo en Postgres) | **Cero** (Nativo) | Requiere scripts externos para leer la cola | **Alta** (Servidores Python, Redis, DevOps) |
| **Límites de Concurrencia (Pools)** | Sí (Válvula estricta configurable) | No | No (Depende de tu script externo) | Sí (Altamente configurable) |
| **Control de Tiempos (Timeouts)** | Auto-kill a nivel de proceso nativo | No | No | Sí (Manejado por el worker externo) |
| **Reintentos Automáticos** | Integrado por tarea | No | Integrado | Integrado |
| **Integración fuera de la BD** | Limitado (Requiere `dblink`/`fdw`) | Limitado | Excelente (Si tu script lo soporta) | **Nativo** (Conecta APIs, Nubes, Servidores) |

---


## 📖 Conoce los Objetos (API)

No te asustes, el sistema usa tablitas muy sencillas para llevar su propio control:

**🗄️ Tablas (Donde guardamos las cosas):**

* `bg.cat_queries`: Aquí se guarda el texto de tus consultas (sin repetirse).
* `bg.def_jobs`: Aquí guardamos las reglas de tu trabajo (límites y reintentos).
* `bg.def_tasks`: Aquí se guarda el orden de los pasos de tu trabajo.
* `bg.run_jobs`: El historial. Aquí se anota a qué hora empezó y terminó el trabajo general.
* `bg.run_tasks`: ¡La cola en vivo! Aquí se guarda el estatus de cada pasito y los mensajes de error.
* `bg.run_tasks_errors_history`: **[NUEVO]** La caja negra forense inmutable. Archiva el estado de la tarea, el número de intento fallido y el texto exacto de la consulta SQL de cualquier transacción antes de que el motor limpie la cola para un ciclo de reintentos.

**👁️ Vistas (Para que audites fácilmente):**

* `bg.vw_status_progreso_corporativo`: Un tablero súper amigable que te muestra el avance %, qué está corriendo y qué falló.
* `bg.vw_trazabilidad_forense`: **[NUEVO]** Vista de texto puro diseñada para DBAs, ORMs y herramientas de automatización. Mide la duración neta de la tarea, la latencia en la cola de espera y los resúmenes de ejecución con precisión de milisegundos.

**⚙️ Funciones (Tus controles principales):**

* `bg.create_job_definition()`: Crea una plantilla para usarla después.
* `bg.start_job()`: Enciende un trabajo que ya habías creado.
* `bg.launch_job_one_shot()`: ¡Todo en uno! Crea y arranca el trabajo en el mismo comando.
* `bg.replicate_query()`: Te ayuda a clonar una consulta muchas veces para hacer pruebas de estrés.
* `bg.abort_job()`: **[NUEVO]** El freno de emergencia global (Kill Switch). Intercepta un trabajo activo, envía una señal de cancelación (SIGINT) para detener al padre orquestador y a todos los trabajadores vivos a nivel del Sistema Operativo, y destruye la cola restante al instante.

---


futuras actualizaciones se tiene pensado ingregar temas de -- 
```
max_prepared_transactions -- para SEQUENTIAL_STRICT o agregar un nuevo modo.
show max_prepared_transactions; -- permitira revertir todo en caso de algo mal pase,
-- para esto el proceso 1 realiza su trabajo en una transaccion y genera el prepare con un id md5, si es exitoso, el proceso dos hace otro begin y genera otro perare , en caso de que el tercer proceso falle, el orquestador dejara de lanzar el siguiente proceso
en caso de haber y ejecutara un rollback de todos los procesos.


-- especificar que se pueden hacer acciones que no esperan una respuesa como filas, solo un mensaje de error exitoso o fallido.


```




 

