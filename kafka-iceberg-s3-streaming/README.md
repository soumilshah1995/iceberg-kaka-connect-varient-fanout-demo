# Kafka → Iceberg (local) lab

End-to-end flow: **Kafka** → **Kafka Connect (Iceberg sink)** → **Hadoop local warehouse** in Docker, then **read with Spark** on your laptop (Jupyter) using a **symlink** so file paths in Iceberg metadata match the host.

### Lab steps (the order you asked for)

1. **Spin up the stack** — `docker compose up -d` (and build the Iceberg Connect plugin with `scripts/init.sh` on first use).  
2. **Produce messages** — run `data_producer.py` to topic **`orders`** (from the `python` container or from the host; see [Step 6](#step-6--produce-messages-to-orders)). *Messages can be produced before or after the table; the topic will keep them until the sink reads.*  
3. **Create the Iceberg table** — PySpark / Spark SQL with warehouse **`file:///var/iceberg-warehouse`**, table **`dev.default.orders`**, including **`event_variant`** as **VARIANT** if you are testing that path — see [Step 4](#step-4--create-the-iceberg-table-spark--pyspark-on-the-host) and `spark_define_orders_variant.py`. **macOS: create the [symlink](#step-3--symlink-macos--for-spark-on-the-host-only) first.**  
4. **Start the Kafka Connect sink** — `./scripts/register-sink.sh`, then [check status](#step-5--register-and-start-the-kafka-connect-sink) (`iceberg-sink` **RUNNING**).  
5. **Query** — in Spark, `SELECT * FROM dev.default.orders` (see [Step 7](#step-7--query-iceberg-in-spark-jupyter--pyspark)).

*For a **predefined VARIANT schema**, the repo sets `iceberg.tables.auto-create-enabled: false` and expects the table to exist before the sink can write. If you create the table in step 3, use step 4 after that. If the sink is registered first with `auto-create: true`, it may infer structs instead of VARIANT until you `DROP` and recreate the table and turn auto-create off.*

| Service        | Port (host) | Notes                                      |
|---------------|-------------|---------------------------------------------|
| Kafka (KRaft) | 9092, 29092 | From host, use **29092** for `PLAINTEXT_HOST` |
| Iceberg Connect | **8084**  | `connectors/register-iceberg-sink.json`   |
| Debezium Connect | 8083     | (optional; second worker in compose)      |
| Kafka UI      | 8080        | Browse topics, Connect                    |

Connect image must be **Java 17+** (this repo uses `confluentinc/cp-kafka-connect-base:7.7.0`) because the Apache Iceberg connector JARs are built for Java 17.

---

## Step 1 — Build the Iceberg Connect plugin (first time)

From the repo, build the runtime zip (or copy an existing `kafka-connect/` tree from a prior build):

```bash
cd scripts
./init.sh
```

Unpacked connector layout should include `../kafka-connect/iceberg-kafka-connect-runtime-*/` with the Iceberg JARs.

---

## Step 2 — Start the stack

```bash
cd /path/to/kafka-iceberg-s3-streaming
docker compose up -d
```

- **Connect** uses warehouse `file:/var/iceberg-warehouse` **inside the container**, bind-mounted to `./iceberg-warehouse` on the host.
- If `custom-smt/.../custom-smt.jar` is missing, create an empty file at that path or remove that volume from `docker-compose.yml` (optional for this lab).

**Check Connect:**

```bash
curl -sS http://localhost:8084/
```

---

## Step 3 — Symlink (macOS, for Spark on the host only)

Connect writes **absolute** paths like `file:/var/iceberg-warehouse/...` in Iceberg metadata. Your laptop does not have that path by default, but the same files exist under the project’s `iceberg-warehouse/`. A symlink makes `file:/var/iceberg-warehouse` resolve to the same data on disk when you run **PySpark outside Docker**.

**One-time (adjust the path to your project):**

```bash
sudo mkdir -p /var
sudo ln -sf /path/to/study-learn/kafka-iceberg-sink-fanout/kafka-iceberg-s3-streaming/iceberg-warehouse /var/iceberg-warehouse
ls -la /var/iceberg-warehouse
```

*Skip this if you only read Iceberg from a Spark container that mounts `/var/iceberg-warehouse` the same way as Connect.*

---

## Step 4 — Create the Iceberg table (Spark / PySpark on the host)

**Before** registering the sink with `iceberg.tables.auto-create-enabled: false`, define `default.orders` so the schema can include a **`VARIANT`** column for `event_variant` (see [Iceberg #15283](https://github.com/apache/iceberg/pull/15283) for connect support).

- Catalog: `dev` (arbitrary name in Spark config)  
- Namespace: `default`  
- Table: `orders` (must match `iceberg.tables` in the JSON: `default.orders`)  
- Warehouse in Spark: **`file:///var/iceberg-warehouse`** (with symlink in place on macOS)

Use `spark_define_orders_variant.py` in this folder or run the equivalent in Jupyter: `DROP` if needed, then `CREATE TABLE ... event_variant VARIANT ... TBLPROPERTIES ('format-version' = '3')`. Use **PySpark 4.x** and `iceberg-spark-runtime-4.0_2.13:1.10.0` (or a matching 3.5 line if you stay on PySpark 3.x).

**Always query with the three-part name:** `dev.default.orders` (not `default.orders` alone — that is `spark_catalog`).

---

## Step 5 — Register and start the Kafka Connect sink

Connector config: `connectors/register-iceberg-sink.json` (topic `orders`, static table `default.orders`, hadoop `file:/var/iceberg-warehouse`).

**Register (default URL matches compose port mapping 8084 → 8083):**

```bash
export KAFKA_CONNECT_URL=http://localhost:8084
./scripts/register-sink.sh
```

**Status:**

```bash
curl -sS http://localhost:8084/connectors/iceberg-sink/status
```

Expect `"connector": {"state": "RUNNING"}` and task `RUNNING`.

**Pause / resume (optional):**

```bash
curl -sS -X PUT http://localhost:8084/connectors/iceberg-sink/pause
curl -sS -X PUT http://localhost:8084/connectors/iceberg-sink/resume
```

---

## Step 6 — Produce messages to `orders`

`data_producer.py` targets `bootstrap_servers='broker:9092'` (Docker network). **From inside the `python` container:**

```bash
docker exec -it python  /workspace/data_producer.py
```

**From the host (outside Docker),** set `bootstrap_servers='localhost:29092'` in the producer, or `docker run --network=...` the same way.

Payload fields should match the table (including nested `event_variant` for VARIANT).

---

## Step 7 — Query Iceberg in Spark (Jupyter / PySpark)

After enough time for the sink to commit (see `iceberg.control.commit.interval-ms` in the connector config, default 60s):

```python
WAREHOUSE = "file:///var/iceberg-warehouse"  # with symlink; see step 3
# ... SparkSession with dev catalog, same as define script
spark.sql("SELECT * FROM dev.default.orders LIMIT 20").show(truncate=False)
```

---

## Quick flow summary (the lab order you asked for)

1. **Spin up stack** — `docker compose up -d` (and build `kafka-connect/` / `init.sh` if needed).  
2. **Symlink (Mac) for host Spark** — `/var/iceberg-warehouse` → `.../iceberg-warehouse`.  
3. **Create Iceberg table** — PySpark/Spark SQL `dev.default.orders` (e.g. `spark_define_orders_variant.py`), warehouse `file:///var/iceberg-warehouse`.  
4. **Start the sink** — `./scripts/register-sink.sh` → `curl .../iceberg-sink/status`.  
5. **Produce to `orders`** — `data_producer` (or any JSON producer) from Docker or host.  
6. **Query** — `SELECT` from `dev.default.orders` in Spark.

*Alternative order:* start stack → register sink (with `auto-create-enabled: true` once) to discover schema → then harden to VARIANT and `auto-create: false` as above.

---

## Troubleshooting

| Issue | What to check |
|------|----------------|
| Connect doesn’t list Iceberg plugin | Use Connect **7.7+** (Java 17). |
| `IcebergSinkConnector` not found | JARs not under `CONNECT_PLUGIN_PATH`; rebuild with `init.sh`. |
| Spark `NotFound` on `file:/var/iceberg-warehouse/...` | Symlink (step 3) or read from Spark in Docker. |
| `default.orders` not found in Spark | Use **`dev.default.orders`**. |
| `TABLE_OR_VIEW_NOT_FOUND` for unqualified `orders` | Set catalog/namespace: `dev` + `default` or use three-part name. |
| `orders` not found from Connect / Glue / S3 | This lab uses **local** `file:` warehouse in Connect, not S3. |

---

## Security

- Do **not** commit AWS access keys. Prefer environment variables or a secrets file ignored by git for `connect` in `docker-compose.yml`.
- Rotate any keys that were ever shared in chat or committed.
