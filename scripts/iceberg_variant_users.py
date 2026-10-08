from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()
print("SPARK_VERSION", spark.version)

spark.sql("CREATE NAMESPACE IF NOT EXISTS lab.test")
spark.sql("DROP TABLE IF EXISTS lab.test.users")
spark.sql(
    """
    CREATE TABLE lab.test.users (
        id BIGINT,
        properties VARIANT,
        region STRING
    )
    USING iceberg
    PARTITIONED BY (region)
    TBLPROPERTIES ('format-version' = '3')
    """
)
spark.sql(
    """
    INSERT INTO lab.test.users VALUES
    (1, parse_json('{"name":"Alice","address":{"city":"NYC"}}'), 'us-east'),
    (2, parse_json('{"name":"Bob","address":{"city":"LA"}}'), 'us-west'),
    (3, parse_json('{"name":"Carol","address":{"city":"Chicago"}}'), 'us-central')
    """
)

rows = spark.sql(
    """
    SELECT
        id,
        region,
        cast(properties AS STRING) AS properties,
        variant_get(properties, '$.name', 'string') AS name,
        variant_get(properties, '$.address.city', 'string') AS city
    FROM lab.test.users
    ORDER BY id
    """
).collect()

for row in rows:
    print(
        "USER_ROW",
        f"id={row['id']}",
        f"region={row['region']}",
        f"name={row['name']}",
        f"city={row['city']}",
        f"properties={row['properties']}",
    )

print("USER_ROW_COUNT", len(rows))
if len(rows) != 3:
    raise SystemExit(f"expected 3 users, found {len(rows)}")
