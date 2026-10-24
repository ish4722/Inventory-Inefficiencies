-- Mastercard Performance Analytics | MySQL 8.0+
-- KPI suite: data-quality checks, stockouts, forecast error, rolling demand, turnover, ABC and reorder heuristic.
-- Revenue exposure and turnover are proxies, not observed business impact.
USE urban_retail_inventory;

-- 1. Executive KPI baseline
WITH daily AS (
 SELECT s.Sale_Date,s.Store_ID,s.Product_ID,s.Units_Sold,f.Demand_Forecast,i.Inventory_Level,p.Price,
 ABS(s.Units_Sold-f.Demand_Forecast) abs_error,
 CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN 1 ELSE 0 END stockout_with_demand
 FROM Sales s JOIN Forecast f ON f.Forecast_Date=s.Sale_Date AND f.Store_ID=s.Store_ID AND f.Product_ID=s.Product_ID
 JOIN Inventory i ON i.Inventory_Date=s.Sale_Date AND i.Store_ID=s.Store_ID AND i.Product_ID=s.Product_ID
 JOIN Product p ON p.Product_ID=s.Product_ID)
SELECT COUNT(*) sku_store_days,SUM(Units_Sold) units_sold,ROUND(SUM(Units_Sold*Price),2) sales_value_proxy,
ROUND(AVG(abs_error),2) mae_units,
ROUND(AVG(CASE WHEN Demand_Forecast=0 THEN NULL ELSE abs_error/Demand_Forecast END)*100,2) mape_pct,
SUM(stockout_with_demand) stockout_days_with_demand,
ROUND(SUM(CASE WHEN stockout_with_demand=1 THEN Demand_Forecast*Price ELSE 0 END),2) estimated_revenue_exposure
FROM daily;

-- 2. Data-quality checks at date x store x product grain
SELECT 'sales_duplicate_grain' check_name,COUNT(*) issue_count FROM
(SELECT Sale_Date,Store_ID,Product_ID FROM Sales GROUP BY Sale_Date,Store_ID,Product_ID HAVING COUNT(*)>1) d
UNION ALL SELECT 'negative_units_sold',COUNT(*) FROM Sales WHERE Units_Sold<0
UNION ALL SELECT 'negative_inventory',COUNT(*) FROM Inventory WHERE Inventory_Level<0
UNION ALL SELECT 'negative_forecast',COUNT(*) FROM Forecast WHERE Demand_Forecast<0
UNION ALL SELECT 'missing_product_dimension',COUNT(*) FROM Sales s LEFT JOIN Product p ON p.Product_ID=s.Product_ID WHERE p.Product_ID IS NULL
UNION ALL SELECT 'missing_store_dimension',COUNT(*) FROM Sales s LEFT JOIN Store st ON st.Store_ID=s.Store_ID WHERE st.Store_ID IS NULL;

-- 3. SKU-store stockout and directional revenue exposure
SELECT i.Store_ID,i.Product_ID,COUNT(*) observed_days,
SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN 1 ELSE 0 END) stockout_days,
ROUND(100.0*SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0),2) stockout_day_pct,
SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN f.Demand_Forecast ELSE 0 END) forecast_units_at_risk,
ROUND(SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN f.Demand_Forecast*p.Price ELSE 0 END),2) estimated_revenue_exposure
FROM Inventory i JOIN Forecast f ON f.Forecast_Date=i.Inventory_Date AND f.Store_ID=i.Store_ID AND f.Product_ID=i.Product_ID
JOIN Product p ON p.Product_ID=i.Product_ID GROUP BY i.Store_ID,i.Product_ID HAVING stockout_days>0
ORDER BY estimated_revenue_exposure DESC,stockout_days DESC;

-- 4. Rolling seven-observation demand average (not necessarily seven consecutive calendar days)
WITH d AS (SELECT Sale_Date,Store_ID,Product_ID,SUM(Units_Sold) daily_units FROM Sales GROUP BY Sale_Date,Store_ID,Product_ID),
r AS (SELECT Sale_Date,Store_ID,Product_ID,daily_units,
AVG(daily_units) OVER(PARTITION BY Store_ID,Product_ID ORDER BY Sale_Date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) rolling_avg,
COUNT(*) OVER(PARTITION BY Store_ID,Product_ID ORDER BY Sale_Date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) n FROM d)
SELECT Sale_Date,Store_ID,Product_ID,daily_units,ROUND(rolling_avg,2) rolling_7_observation_avg,n FROM r WHERE n=7
ORDER BY Store_ID,Product_ID,Sale_Date;

-- 5. Forecast error by store/category; WAPE is useful across groups of differing sizes
WITH e AS (SELECT s.Store_ID,p.Category,s.Units_Sold,ABS(s.Units_Sold-f.Demand_Forecast) abs_error
FROM Sales s JOIN Forecast f ON f.Forecast_Date=s.Sale_Date AND f.Store_ID=s.Store_ID AND f.Product_ID=s.Product_ID
JOIN Product p ON p.Product_ID=s.Product_ID)
SELECT Store_ID,Category,COUNT(*) observations,ROUND(AVG(abs_error),2) mae,
ROUND(100*AVG(CASE WHEN Units_Sold>0 THEN abs_error/Units_Sold END),2) mape_pct_nonzero_actuals,
ROUND(100*SUM(abs_error)/NULLIF(SUM(Units_Sold),0),2) wape_pct
FROM e GROUP BY Store_ID,Category ORDER BY wape_pct DESC;

-- 6. Unit turnover and inventory value proxies; finance-grade turnover needs COGS and avg inventory value
SELECT s.Product_ID,p.Category,SUM(s.Units_Sold) units_sold,ROUND(AVG(i.Inventory_Level),2) avg_on_hand_units,
ROUND(SUM(s.Units_Sold)/NULLIF(AVG(i.Inventory_Level),0),2) unit_turnover_proxy,
ROUND(AVG(i.Inventory_Level)*MAX(p.Price),2) avg_inventory_value_proxy
FROM Sales s JOIN Inventory i ON i.Inventory_Date=s.Sale_Date AND i.Store_ID=s.Store_ID AND i.Product_ID=s.Product_ID
JOIN Product p ON p.Product_ID=s.Product_ID GROUP BY s.Product_ID,p.Category ORDER BY unit_turnover_proxy DESC;

-- 7. ABC classes based on estimated sales value; confirm Discount is stored as percentage points before use
WITH pr AS (SELECT p.Product_ID,p.Category,SUM(s.Units_Sold*p.Price*(1-COALESCE(p.Discount,0)/100.0)) revenue_proxy
FROM Sales s JOIN Product p ON p.Product_ID=s.Product_ID GROUP BY p.Product_ID,p.Category),
c AS (SELECT Product_ID,Category,revenue_proxy,SUM(revenue_proxy) OVER(ORDER BY revenue_proxy DESC,Product_ID) cumulative_revenue,
SUM(revenue_proxy) OVER() total_revenue FROM pr)
SELECT Product_ID,Category,ROUND(revenue_proxy,2) revenue_proxy,
ROUND(100*cumulative_revenue/NULLIF(total_revenue,0),2) cumulative_revenue_pct,
CASE WHEN cumulative_revenue/NULLIF(total_revenue,0)<=.80 THEN 'A' WHEN cumulative_revenue/NULLIF(total_revenue,0)<=.95 THEN 'B' ELSE 'C' END abc_class
FROM c ORDER BY revenue_proxy DESC;

-- 8. Transparent reorder heuristic. Replace assumed lead time/safety days with measured distributions and service levels
SET @assumed_lead_time_days:=5; SET @safety_days:=3;
WITH d AS (SELECT Sale_Date,Store_ID,Product_ID,SUM(Units_Sold) daily_units FROM Sales GROUP BY Sale_Date,Store_ID,Product_ID),
a AS (SELECT Store_ID,Product_ID,AVG(daily_units) avg_daily_demand,STDDEV_POP(daily_units) demand_stddev FROM d GROUP BY Store_ID,Product_ID),
st AS (SELECT Store_ID,Product_ID,AVG(Inventory_Level) avg_inventory,MIN(Inventory_Level) min_inventory FROM Inventory GROUP BY Store_ID,Product_ID)
SELECT a.Store_ID,a.Product_ID,ROUND(a.avg_daily_demand,2) avg_daily_demand,ROUND(a.demand_stddev,2) demand_stddev,
ROUND(st.avg_inventory,2) avg_inventory,ROUND(a.avg_daily_demand*(@assumed_lead_time_days+@safety_days),0) reorder_threshold,
GREATEST(0,CEIL(a.avg_daily_demand*(@assumed_lead_time_days+@safety_days)-st.min_inventory)) indicative_replenishment_units
FROM a JOIN st ON st.Store_ID=a.Store_ID AND st.Product_ID=a.Product_ID ORDER BY indicative_replenishment_units DESC;

-- 9. Descriptive promotion/weather comparison; this is association, not causation
SELECT e.Weather_Conditions,e.Holiday_Promotion,COUNT(*) joined_rows,ROUND(AVG(s.Units_Sold),2) avg_units_sold,
ROUND(AVG(s.Units_Sold*p.Price),2) avg_sales_value_proxy
FROM Sales s JOIN External_Factors e ON e.Factor_Date=s.Sale_Date AND e.Store_ID=s.Store_ID
JOIN Product p ON p.Product_ID=s.Product_ID GROUP BY e.Weather_Conditions,e.Holiday_Promotion ORDER BY avg_units_sold DESC;

-- 10. Prioritized analyst investigation queue; thresholds are illustrative and need calibration
WITH q AS (SELECT i.Store_ID,i.Product_ID,
SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN 1 ELSE 0 END) stockout_days,
SUM(ABS(s.Units_Sold-f.Demand_Forecast)) total_abs_error,
SUM(CASE WHEN i.Inventory_Level=0 AND f.Demand_Forecast>0 THEN f.Demand_Forecast*p.Price ELSE 0 END) revenue_exposure
FROM Inventory i JOIN Forecast f ON f.Forecast_Date=i.Inventory_Date AND f.Store_ID=i.Store_ID AND f.Product_ID=i.Product_ID
JOIN Sales s ON s.Sale_Date=i.Inventory_Date AND s.Store_ID=i.Store_ID AND s.Product_ID=i.Product_ID
JOIN Product p ON p.Product_ID=i.Product_ID GROUP BY i.Store_ID,i.Product_ID)
SELECT Store_ID,Product_ID,stockout_days,total_abs_error,ROUND(revenue_exposure,2) estimated_revenue_exposure,
CASE WHEN stockout_days>=5 OR revenue_exposure>=10000 THEN 'P1 - Investigate now'
WHEN stockout_days>=2 OR revenue_exposure>=2500 THEN 'P2 - Review this week' ELSE 'P3 - Monitor' END analyst_priority
FROM q WHERE stockout_days>0 OR total_abs_error>0
ORDER BY CASE WHEN stockout_days>=5 OR revenue_exposure>=10000 THEN 1 WHEN stockout_days>=2 OR revenue_exposure>=2500 THEN 2 ELSE 3 END,
revenue_exposure DESC,total_abs_error DESC;
