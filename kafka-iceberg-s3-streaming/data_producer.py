try:
    from kafka import KafkaProducer
    from faker import Faker
    import json
    import random
    import uuid
    from datetime import datetime
    print("All modules loaded ")
except Exception as e:
    print("error modules ", e)

producer = KafkaProducer(bootstrap_servers='broker:9092')
faker = Faker()

# Sites with weighted distribution
SITE_IDS = ["siteA", "siteB", "siteC", "siteD"]
SITE_WEIGHTS = [0.6, 0.3, 0.08, 0.02]

class DataGenerator(object):
    @staticmethod
    def nested_variant_blob(site_or_order="site"):
        """
        One JSON object with nested maps/lists/mixed types — map this column
        to VARIANT in Iceberg to exercise Kafka Connect RecordConverter
        (see apache/iceberg#15283, VARIANT in sink).
        """
        return {
            "schema_version": 1,
            "kind": site_or_order,
            "user": {
                "id": str(uuid.uuid4())[:12],
                "labels": [faker.word() for _ in range(random.randint(1, 3))],
                "prefs": {
                    "theme": random.choice(["light", "dark"]),
                    "notify": random.choice([True, False]),
                },
            },
            "line_items": [
                {
                    "sku": faker.bothify(text="??-###").upper(),
                    "qty": random.randint(1, 5),
                    "unit_price": str(round(random.uniform(1.0, 99.99), 2)),
                }
                for _ in range(random.randint(1, 2))
            ],
            "scores": {f"k{i}": random.randint(0, 100) for i in range(2)},
            "at": datetime.now().isoformat(),
            "note": None if random.random() < 0.2 else faker.sentence(nb_words=4),
        }

    @staticmethod
    def get_site_data():
        site_id = random.choices(SITE_IDS, weights=SITE_WEIGHTS, k=1)[0]
        # Prepend default. namespace to site_id to form full Iceberg table identifier
        namespaced_site_id = f"{site_id}"
        site_data = {
            "record_id": str(uuid.uuid4()),   # just to keep uniqueness
            "site_id": namespaced_site_id,
            "region": faker.state(),
            "city": faker.city(),
            "created_at": datetime.now().isoformat(),
            "ts": str(datetime.now().timestamp()),
            # single nested field for VARIANT sink tests
            "event_variant": DataGenerator.nested_variant_blob("site"),
        }
        return site_data

    @staticmethod
    def get_orders_data(site_id):
        priority = random.choice(["LOW", "MEDIUM", "HIGH"])
        order_data = {
            "iceberg_table": f"default.orders_{site_id}",
            "order_id": str(uuid.uuid4()),
            "site_id": site_id,
            "product_name": faker.word(),
            "order_value": str(random.randint(10, 1000)),
            "priority": priority,
            "order_date": faker.date_between(start_date='-30d', end_date='today').strftime('%Y-%m-%d'),
            "ts": str(datetime.now().timestamp()),
            "event_variant": DataGenerator.nested_variant_blob("order"),
        }
        return order_data, priority


# Generate synthetic events
for _ in range(20):
    # Generate and send site-level event with namespaced site_id
    site_data = DataGenerator.get_site_data()
    site_payload = json.dumps(site_data).encode("utf-8")
    producer.send('sites', site_payload)
    print("Site Payload:", site_payload)

    # Generate and send orders tied to the same namespaced site
    for i in range(random.randint(1, 5)):  # variable number of orders per site
        order_data, priority = DataGenerator.get_orders_data(site_data["site_id"])
        order_payload = json.dumps(order_data).encode("utf-8")
        # Connect Filter + HasHeaderKey(iceberg-priority-high) + negate: only HIGH has this header; others dropped
        h = [("iceberg-priority-high", b"1")] if priority == "HIGH" else None
        producer.send("orders", value=order_payload, headers=h)
        print("Order Payload:", order_payload, "header iceberg-priority-high" if h else "no header (sink drops)")
