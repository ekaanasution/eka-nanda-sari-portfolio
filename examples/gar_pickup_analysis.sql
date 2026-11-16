-- GAR PICKUP CANNIBALIZATION & INCREMENTAL ADS
-- BigQuery Standard SQL | Portfolio example based on the GAR report structure
-- Baseline: 21 Jul 2026 - 17 Aug 2026 (28 days)
-- GAR launch: 18 Aug 2026 | Review horizon: 80 days
--
-- The SQL below demonstrates the store-level ADS method.
-- Replace the source table/field identifiers with the production schema.
-- Keep one row per store x date x channel before calculating period ADS.

DECLARE baseline_start DATE DEFAULT DATE '2026-07-21';
DECLARE baseline_end   DATE DEFAULT DATE '2026-08-17';
DECLARE gar_start      DATE DEFAULT DATE '2026-08-18';
DECLARE gar_end_date   DATE DEFAULT @gar_end_date;

WITH source_sales AS (
  SELECT
    sales_date,
    CAST(branch_id AS STRING) AS code_gis,
    CASE
      WHEN UPPER(TRIM(channel)) IN ('DINE IN', 'DINE-IN') THEN 'DINE IN'
      WHEN UPPER(TRIM(channel)) IN ('TAKE AWAY', 'TAKEAWAY') THEN 'TAKE AWAY'
      WHEN UPPER(TRIM(channel)) IN (
        'GOFOOD', 'GRABFOOD', 'SHOPEEFOOD', 'ONLINE'
      ) THEN 'ONLINE'
      WHEN UPPER(TRIM(channel)) = 'PICKUP' THEN 'PICKUP'
      ELSE 'OTHER'
    END AS channel_group,
    SUM(net_sales) AS net_sales
  FROM `YOUR_PROJECT.gold_bi.daily_store_channel_sku_summary`
  WHERE sales_date BETWEEN baseline_start AND gar_end_date
  GROUP BY 1, 2, 3
),

-- Aggregate to one record per store and date.
store_day AS (
  SELECT
    sales_date,
    code_gis,
    SUM(IF(channel_group = 'DINE IN', net_sales, 0)) AS dine_in_sales,
    SUM(IF(channel_group = 'TAKE AWAY', net_sales, 0)) AS take_away_sales,
    SUM(IF(channel_group = 'ONLINE', net_sales, 0)) AS online_sales,
    SUM(IF(channel_group = 'PICKUP', net_sales, 0)) AS pickup_sales,
    SUM(IF(
      channel_group IN ('DINE IN', 'TAKE AWAY', 'ONLINE'),
      net_sales, 0
    )) AS existing_channel_sales,
    SUM(IF(
      channel_group IN ('DINE IN', 'TAKE AWAY', 'ONLINE', 'PICKUP'),
      net_sales, 0
    )) AS total_sales
  FROM source_sales
  GROUP BY 1, 2
),

-- ADS / store = sales during the period divided by observed operating days.
store_period_ads AS (
  SELECT
    code_gis,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             total_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_total_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             total_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_total_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             existing_channel_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_existing_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             existing_channel_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_existing_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             pickup_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_pickup_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             pickup_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_pickup_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             dine_in_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_dine_in_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             dine_in_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_dine_in_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             take_away_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_take_away_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             take_away_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_take_away_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN baseline_start AND baseline_end,
             online_sales, 0)),
      COUNTIF(sales_date BETWEEN baseline_start AND baseline_end)
    ) AS baseline_online_ads,

    SAFE_DIVIDE(
      SUM(IF(sales_date BETWEEN gar_start AND gar_end_date,
             online_sales, 0)),
      COUNTIF(sales_date BETWEEN gar_start AND gar_end_date)
    ) AS gar_online_ads

  FROM store_day
  GROUP BY code_gis
),

store_deltas AS (
  SELECT
    *,
    gar_total_ads - baseline_total_ads AS delta_total_ads,
    gar_existing_ads - baseline_existing_ads AS delta_existing_ads,
    gar_pickup_ads - baseline_pickup_ads AS pickup_delta_ads,
    GREATEST(baseline_existing_ads - gar_existing_ads, 0)
      AS existing_channel_decline_ads
  FROM store_period_ads
),

impact_calc AS (
  SELECT
    *,
    LEAST(
      GREATEST(pickup_delta_ads, 0),
      existing_channel_decline_ads
    ) AS cannibalized_ads,

    GREATEST(
      GREATEST(pickup_delta_ads, 0)
      - LEAST(
          GREATEST(pickup_delta_ads, 0),
          existing_channel_decline_ads
        ),
      0
    ) AS incremental_ads
  FROM store_deltas
)

SELECT
  code_gis,
  baseline_total_ads,
  gar_total_ads,
  delta_total_ads,
  SAFE_DIVIDE(delta_total_ads, baseline_total_ads) AS delta_ads_pct,
  baseline_existing_ads,
  gar_existing_ads,
  delta_existing_ads,
  existing_channel_decline_ads,
  baseline_pickup_ads,
  gar_pickup_ads,
  pickup_delta_ads,
  cannibalized_ads,
  incremental_ads,

  SAFE_DIVIDE(cannibalized_ads, NULLIF(pickup_delta_ads, 0))
    AS cannibalization_rate,

  CASE
    WHEN pickup_delta_ads <= 0 THEN 'NO PICKUP GROWTH'
    WHEN existing_channel_decline_ads >= pickup_delta_ads
      THEN 'FULL CANNIBALIZATION'
    WHEN existing_channel_decline_ads > 0
      THEN 'PARTIAL CANNIBALIZATION'
    ELSE 'NO CANNIBALIZATION'
  END AS cannibalization_status,

  -- Impact-status rule used in the GAR store-level analysis:
  -- L = total ADS delta; H = Pickup ADS growth.
  CASE
    WHEN delta_total_ads < 0 THEN 'NON IMPACT'
    WHEN delta_total_ads <= pickup_delta_ads THEN 'IMPACT PARTIAL'
    ELSE 'IMPACT FULL'
  END AS impact_status,

  GREATEST(baseline_dine_in_ads - gar_dine_in_ads, 0)
    AS dine_in_decline_ads,
  GREATEST(baseline_take_away_ads - gar_take_away_ads, 0)
    AS take_away_decline_ads,
  GREATEST(baseline_online_ads - gar_online_ads, 0)
    AS online_decline_ads,

  CASE
    WHEN GREATEST(baseline_dine_in_ads - gar_dine_in_ads, 0)
       >= GREATEST(baseline_take_away_ads - gar_take_away_ads, 0)
     AND GREATEST(baseline_dine_in_ads - gar_dine_in_ads, 0)
       >= GREATEST(baseline_online_ads - gar_online_ads, 0)
      THEN 'DINE IN'
    WHEN GREATEST(baseline_take_away_ads - gar_take_away_ads, 0)
       >= GREATEST(baseline_online_ads - gar_online_ads, 0)
      THEN 'TAKE AWAY'
    ELSE 'ONLINE'
  END AS main_existing_channel_source

FROM impact_calc
ORDER BY delta_total_ads ASC;
