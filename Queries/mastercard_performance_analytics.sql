-- Mastercard Performance Analytics upgrade
-- MySQL 8.0+
-- Assumes normalized tables created by Queries/DataLoading.sql:
-- Sales(Sale_Date, Store_ID, Product_ID, Units_Sold)
-- Inventory(Inventory_Date, Store_ID, Product_ID, Inventory_Level)
-- Forecast(Forecast_Date, Store_ID, Product_ID, Demand_Forecast)
-- Product(Product_ID, Category, Price, Discount, Seasonality, Supplier_Rating)
-- Store(Store_ID, Region)
--
-- IMPORTANT: Stockout lost-sales estimates are proxies, not observed lost sales.
-- Validate assumptions before presenting estimates as business impact.

USE urban_retail_inventory;

-- 1. Executive KPI baseline: sales, inventory exposure, forecast error, stockout days.
WITH daily AS (
    SELECT
        s.Sale_Date,
        s.Store_ID,
        s.Product_ID,
        s.Units_Sold,
        f.Demand_Forecast,
        i.Inventory_Level,
        p.Price,
        ABS(s.Units_Sold - f.Demand_Forecast) AS abs_error,
        CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN 1 ELSE 0 END AS stockout_with_demand
    FROM Sales s
    JOIN Forecast f
      ON f.Forecast_Date = s.Sale_Date
     AND f.Store_ID = s.Store_ID
     AND f.Product_ID = s.Product_ID
    JOIN Inventory i
      ON i.Inventory_Date = s.Sale_Date
     AND i.Store_ID = s.Store_ID
     AND i.Product_ID = s.Product_ID
    JOIN Product p ON p.Product_ID = s.Product_ID
)
SELECT
    COUNT(*) AS sku_store_days,
    SUM(Units_Sold) AS units_sold,
    ROUND(SUM(Units_Sold * Price), 2) AS gross_sales_value_proxy,
    ROUND(AVG(abs_error), 2) AS mean_absolute_error_units,
    ROUND(AVG(CASE WHEN Demand_Forecast = 0 THEN NULL
                   ELSE abs_error / Demand_Forecast END) * 100, 2) AS mean_absolute_percentage_error_pct,
    SUM(stockout_with_demand) AS stockout_days_with_forecast_demand,
    ROUND(SUM(CASE WHEN stockout_with_demand = 1 THEN Demand_Forecast * Price ELSE 0 END), 2)
        AS estimated_stockout_revenue_exposure
FROM daily;

-- 2. Data quality checks: duplicates at expected SKU-store-day grain and invalid values.
SELECT 'sales_duplicate_grain' AS check_name, COUNT(*) AS issue_count
FROM (
    SELECT Sale_Date, Store_ID, Product_ID
    FROM Sales GROUP BY Sale_Date, Store_ID, Product_ID HAVING COUNT(*) > 1
) d
UNION ALL
SELECT 'negative_units_sold', COUNT(*) FROM Sales WHERE Units_Sold < 0
UNION ALL
SELECT 'negative_inventory', COUNT(*) FROM Inventory WHERE Inventory_Level < 0
UNION ALL
SELECT 'negative_forecast', COUNT(*) FROM Forecast WHERE Demand_Forecast < 0
UNION ALL
SELECT 'missing_product_dimension', COUNT(*)
FROM Sales s LEFT JOIN Product p ON p.Product_ID = s.Product_ID WHERE p.Product_ID IS NULL
UNION ALL
SELECT 'missing_store_dimension', COUNT(*)
FROM Sales s LEFT JOIN Store st ON st.Store_ID = s.Store_ID WHERE st.Store_ID IS NULL;

-- 3. Stockout frequency and revenue exposure by SKU-store.
-- Demand forecast x list price is a directional exposure proxy, not guaranteed lost sales.
SELECT
    i.Store_ID,
    i.Product_ID,
    COUNT(*) AS observed_days,
    SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN 1 ELSE 0 END) AS stockout_days,
    ROUND(100.0 * SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2) AS stockout_day_pct,
    SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN f.Demand_Forecast ELSE 0 END) AS forecast_units_at_risk,
    ROUND(SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN f.Demand_Forecast * p.Price ELSE 0 END), 2)
        AS estimated_revenue_exposure
FROM Inventory i
JOIN Forecast f
  ON f.Forecast_Date = i.Inventory_Date AND f.Store_ID = i.Store_ID AND f.Product_ID = i.Product_ID
JOIN Product p ON p.Product_ID = i.Product_ID
GROUP BY i.Store_ID, i.Product_ID
HAVING stockout_days > 0
ORDER BY estimated_revenue_exposure DESC, stockout_days DESC;

-- 4. Weekly demand, seven-day rolling average, and next-week baseline.
WITH product_daily AS (
    SELECT Sale_Date, Store_ID, Product_ID, SUM(Units_Sold) AS daily_units
    FROM Sales
    GROUP BY Sale_Date, Store_ID, Product_ID
),
rolled AS (
    SELECT
        Sale_Date, Store_ID, Product_ID, daily_units,
        AVG(daily_units) OVER (
            PARTITION BY Store_ID, Product_ID
            ORDER BY Sale_Date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7_day_avg,
        COUNT(*) OVER (
            PARTITION BY Store_ID, Product_ID
            ORDER BY Sale_Date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS window_days
    FROM product_daily
)
SELECT Sale_Date, Store_ID, Product_ID, daily_units,
       ROUND(rolling_7_day_avg, 2) AS rolling_7_day_avg,
       window_days
FROM rolled
WHERE window_days = 7
ORDER BY Store_ID, Product_ID, Sale_Date;

-- 5. Forecast evaluation by store and category.
-- MAPE excludes zero actual demand to avoid division-by-zero distortion; WAPE is also reported.
WITH e AS (
    SELECT s.Store_ID, p.Category, s.Sale_Date, s.Units_Sold, f.Demand_Forecast,
           ABS(s.Units_Sold - f.Demand_Forecast) AS abs_error
    FROM Sales s
    JOIN Forecast f ON f.Forecast_Date = s.Sale_Date
       AND f.Store_ID = s.Store_ID AND f.Product_ID = s.Product_ID
    JOIN Product p ON p.Product_ID = s.Product_ID
)
SELECT Store_ID, Category,
       COUNT(*) AS observations,
       ROUND(AVG(abs_error), 2) AS mae,
       ROUND(100.0 * AVG(CASE WHEN Units_Sold > 0 THEN abs_error / Units_Sold END), 2) AS mape_pct_nonzero_actuals,
       ROUND(100.0 * SUM(abs_error) / NULLIF(SUM(Units_Sold), 0), 2) AS wape_pct
FROM e
GROUP BY Store_ID, Category
ORDER BY wape_pct DESC;

-- 6. Inventory turnover proxy by product.
-- This is a simplified units-sold / average-on-hand measure. Use COGS and average inventory
-- value for a finance-grade turnover ratio when those fields are available.
SELECT
    s.Product_ID,
    p.Category,
    SUM(s.Units_Sold) AS units_sold,
    ROUND(AVG(i.Inventory_Level), 2) AS avg_on_hand_units,
    ROUND(SUM(s.Units_Sold) / NULLIF(AVG(i.Inventory_Level), 0), 2) AS unit_turnover_proxy,
    ROUND(AVG(i.Inventory_Level) * MAX(p.Price), 2) AS average_inventory_value_proxy
FROM Sales s
JOIN Inventory i ON i.Inventory_Date = s.Sale_Date
    AND i.Store_ID = s.Store_ID AND i.Product_ID = s.Product_ID
JOIN Product p ON p.Product_ID = s.Product_ID
GROUP BY s.Product_ID, p.Category
ORDER BY unit_turnover_proxy DESC;

-- 7. ABC product segmentation by cumulative revenue contribution.
WITH product_revenue AS (
    SELECT p.Product_ID, p.Category,
           SUM(s.Units_Sold * p.Price * (1 - COALESCE(p.Discount, 0) / 100.0)) AS revenue_proxy
    FROM Sales s
    JOIN Product p ON p.Product_ID = s.Product_ID
    GROUP BY p.Product_ID, p.Category
),
cumulative AS (
    SELECT Product_ID, Category, revenue_proxy,
           SUM(revenue_proxy) OVER (ORDER BY revenue_proxy DESC, Product_ID) AS cumulative_revenue,
           SUM(revenue_proxy) OVER () AS total_revenue
    FROM product_revenue
)
SELECT Product_ID, Category, ROUND(revenue_proxy, 2) AS revenue_proxy,
       ROUND(100 * cumulative_revenue / NULLIF(total_revenue, 0), 2) AS cumulative_revenue_pct,
       CASE
           WHEN cumulative_revenue / NULLIF(total_revenue, 0) <= 0.80 THEN 'A'
           WHEN cumulative_revenue / NULLIF(total_revenue, 0) <= 0.95 THEN 'B'
           ELSE 'C'
       END AS abc_class
FROM cumulative
ORDER BY revenue_proxy DESC;

-- 8. Reorder suggestions using demand during lead time + safety buffer.
-- Replace assumed lead-time days and service-level buffer with empirically estimated values.
SET @assumed_lead_time_days := 5;
SET @safety_days := 3;
WITH daily AS (
    SELECT Sale_Date, Store_ID, Product_ID, SUM(Units_Sold) AS daily_units
    FROM Sales
    GROUP BY Sale_Date, Store_ID, Product_ID
),
avg_demand AS (
    SELECT Store_ID, Product_ID, AVG(daily_units) AS avg_daily_demand,
           STDDEV_POP(daily_units) AS demand_stddev
    FROM daily
    GROUP BY Store_ID, Product_ID
),
current_stock AS (
    SELECT Store_ID, Product_ID, AVG(Inventory_Level) AS avg_inventory,
           MIN(Inventory_Level) AS min_observed_inventory
    FROM Inventory
    GROUP BY Store_ID, Product_ID
)
SELECT a.Store_ID, a.Product_ID,
       ROUND(a.avg_daily_demand, 2) AS avg_daily_demand,
       ROUND(a.demand_stddev, 2) AS demand_stddev,
       ROUND(c.avg_inventory, 2) AS avg_inventory,
       ROUND(a.avg_daily_demand * (@assumed_lead_time_days + @safety_days), 0) AS suggested_reorder_threshold,
       GREATEST(0, CEIL(a.avg_daily_demand * (@assumed_lead_time_days + @safety_days) - c.min_observed_inventory))
           AS indicative_replenishment_units
FROM avg_demand a
JOIN current_stock c ON c.Store_ID = a.Store_ID AND c.Product_ID = a.Product_ID
ORDER BY indicative_replenishment_units DESC;

-- 9. Promotion / weather diagnostic: descriptive association only, not causal attribution.
SELECT e.Weather_Conditions, e.Holiday_Promotion,
       COUNT(*) AS store_days,
       ROUND(AVG(s.Units_Sold), 2) AS avg_units_sold,
       ROUND(AVG(s.Units_Sold * p.Price), 2) AS avg_sales_value_proxy
FROM Sales s
JOIN External_Factors e ON e.Factor_Date = s.Sale_Date AND e.Store_ID = s.Store_ID
JOIN Product p ON p.Product_ID = s.Product_ID
GROUP BY e.Weather_Conditions, e.Holiday_Promotion
ORDER BY avg_units_sold DESC;

-- 10. Prioritization queue for analyst review.
-- Priority combines stockout exposure with forecast error; tune weights with stakeholders.
WITH issues AS (
    SELECT i.Store_ID, i.Product_ID,
           SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN 1 ELSE 0 END) AS stockout_days,
           SUM(ABS(s.Units_Sold - f.Demand_Forecast)) AS total_abs_error,
           SUM(CASE WHEN i.Inventory_Level = 0 AND f.Demand_Forecast > 0 THEN f.Demand_Forecast * p.Price ELSE 0 END) AS revenue_exposure
    FROM Inventory i
    JOIN Forecast f ON f.Forecast_Date = i.Inventory_Date
      AND f.Store_ID = i.Store_ID AND f.Product_ID = i.Product_ID
    JOIN Sales s ON s.Sale_Date = i.Inventory_Date
      AND s.Store_ID = i.Store_ID AND s.Product_ID = i.Product_ID
    JOIN Product p ON p.Product_ID = i.Product_ID
    GROUP BY i.Store_ID, i.Product_ID
)
SELECT Store_ID, Product_ID, stockout_days, total_abs_error,
       ROUND(revenue_exposure, 2) AS estimated_revenue_exposure,
       CASE
           WHEN stockout_days >= 5 OR revenue_exposure >= 10000 THEN 'P1 - Investigate now'
           WHEN stockout_days >= 2 OR revenue_exposure >= 2500 THEN 'P2 - Review this week'
           ELSE 'P3 - Monitor'
       END AS analyst_priority
FROM issues
WHERE stockout_days > 0 OR total_abs_error > 0
ORDER BY
    CASE WHEN stockout_days >= 5 OR revenue_exposure >= 10000 THEN 1
         WHEN stockout_days >= 2 OR revenue_exposure >= 2500 THEN 2 ELSE 3 END,
    revenue_exposure DESC, total_abs_error DESC;
