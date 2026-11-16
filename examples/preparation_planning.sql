-- PREPARATION PLANNING | BigQuery Standard SQL
-- Example template: replace project, dataset, table and column names
-- with the source schema used in the production environment.
-- Baseline example: September 2026 | 188 stores
-- Day types: WEEKDAY, FRIDAY, WEEKEND

WITH source_sales AS (
  SELECT
    transaction_detail_id,
    updated_at,
    DATE(order_datetime) AS sales_date,
    EXTRACT(HOUR FROM order_datetime) AS sales_hour,
    NULLIF(TRIM(store_code), '') AS store_code,
    UPPER(NULLIF(TRIM(menu_item), '')) AS source_item,
    SAFE_CAST(quantity AS NUMERIC) AS qty_sold,
    UPPER(TRIM(order_status)) AS order_status
  FROM `YOUR_PROJECT.YOUR_DATASET.sales_transaction_items`
  WHERE DATE(order_datetime) BETWEEN DATE '2026-09-01'
                                 AND DATE '2026-09-30'
),

-- 1) Clean source rows:
--    remove invalid keys, non-positive quantity and cancelled transactions;
--    keep the latest version of each transaction detail record.
clean_sales AS (
  SELECT
    sales_date,
    sales_hour,
    store_code,
    COALESCE(m.canonical_item, s.source_item) AS menu_item,
    qty_sold,
    CASE
      WHEN EXTRACT(DAYOFWEEK FROM sales_date) = 6 THEN 'FRIDAY'
      WHEN EXTRACT(DAYOFWEEK FROM sales_date) IN (1, 7) THEN 'WEEKEND'
      ELSE 'WEEKDAY'
    END AS day_type
  FROM source_sales s
  LEFT JOIN `YOUR_PROJECT.YOUR_DATASET.menu_item_mapping` m
    ON s.source_item = UPPER(TRIM(m.source_item))
  WHERE s.transaction_detail_id IS NOT NULL
    AND s.store_code IS NOT NULL
    AND s.source_item IS NOT NULL
    AND s.qty_sold > 0
    AND s.order_status NOT IN ('VOID', 'CANCELLED', 'REFUNDED')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.transaction_detail_id
    ORDER BY s.updated_at DESC
  ) = 1
),

-- 2) Aggregate historical item demand by store, date, day type and hour.
daily_item_hour AS (
  SELECT
    store_code,
    sales_date,
    day_type,
    sales_hour,
    menu_item,
    SUM(qty_sold) AS item_qty
  FROM clean_sales
  GROUP BY 1, 2, 3, 4, 5
),

-- 3) Count observed operating dates per store and day type.
operating_days AS (
  SELECT
    store_code,
    day_type,
    COUNT(DISTINCT sales_date) AS observed_days
  FROM clean_sales
  GROUP BY 1, 2
),

-- 4) Convert historical sales into average hourly item demand.
avg_item_demand AS (
  SELECT
    d.store_code,
    d.day_type,
    d.sales_hour,
    d.menu_item,
    SAFE_DIVIDE(SUM(d.item_qty), MAX(o.observed_days))
      AS avg_item_qty_per_hour
  FROM daily_item_hour d
  JOIN operating_days o
    USING (store_code, day_type)
  GROUP BY 1, 2, 3, 4
),

-- 5) Convert menu demand into preparation component demand
--    using the recipe / preparation master.
component_demand AS (
  SELECT
    a.store_code,
    a.day_type,
    a.sales_hour,
    UPPER(TRIM(r.component_name)) AS component_name,
    SUM(
      a.avg_item_qty_per_hour
      * SAFE_CAST(r.usage_per_sale AS NUMERIC)
    ) AS demand_component_qty,
    MAX(SAFE_CAST(r.batch_size AS NUMERIC)) AS batch_size,
    MAX(SAFE_CAST(r.batch_multiple AS NUMERIC)) AS batch_multiple,
    MAX(SAFE_CAST(r.holding_time_hours AS NUMERIC)) AS holding_time_hours,
    MAX(SAFE_CAST(r.prep_duration_minutes AS NUMERIC))
      AS prep_duration_minutes
  FROM avg_item_demand a
  JOIN `YOUR_PROJECT.YOUR_DATASET.preparation_recipe_master` r
    ON a.menu_item = UPPER(TRIM(r.menu_item))
  GROUP BY 1, 2, 3, 4
)

-- 6) Round demand to the configured batch multiple and estimate batches.
SELECT
  store_code,
  day_type,
  sales_hour,
  component_name,
  ROUND(demand_component_qty, 2) AS demand_component_qty,
  CEIL(
    SAFE_DIVIDE(
      demand_component_qty,
      NULLIF(batch_multiple, 0)
    )
  ) * batch_multiple AS planned_prep_qty,
  CEIL(
    SAFE_DIVIDE(
      CEIL(SAFE_DIVIDE(demand_component_qty, NULLIF(batch_multiple, 0)))
        * batch_multiple,
      NULLIF(batch_size, 0)
    )
  ) AS estimated_batch_count,
  batch_size,
  batch_multiple,
  holding_time_hours,
  prep_duration_minutes
FROM component_demand
WHERE demand_component_qty > 0
ORDER BY store_code, day_type, sales_hour, component_name;
