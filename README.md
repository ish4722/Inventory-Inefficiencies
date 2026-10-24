# Inventory Performance Analytics | Retail Operations Case Study

**Business question:** How can a multi-store retailer balance product availability, working capital, and supplier reliability with repeatable analytics?

This SQL-first case study examines SKU-store-day performance, identifies stockout and overstock signals, evaluates forecast error, segments products by sales-value contribution, and converts findings into a replenishment and investigation workflow.

> **Evidence note:** This repository contains SQL logic and example insight descriptions. It does not establish production impact. Stockout revenue exposure, forecast accuracy, and replenishment quantities must be calculated on the actual source data and validated against assumptions before being reported as outcomes.

## Analytics workflow
1. Structure daily sales, inventory, forecast, product, store, and external-factor data into relational tables.
2. Validate the intended date × store × product grain, missing dimensions, invalid values, duplicates, and join coverage.
3. Measure stockout frequency, forecast error, rolling demand, turnover proxies, and ABC classes.
4. Prioritize SKU-store issues by severity and estimated exposure.
5. Communicate recommendations through a weekly scorecard and action queue.

## Data model
`Store` and `Product` are dimensions. `Sales`, `Inventory`, and `Forecast` contain daily observations by store and product. `External_Factors` stores store-day context such as weather and promotion flags.

Expected fact-table grain: **one row per date × store × product**. Validate it before joining facts to avoid row multiplication.

## KPI definitions
| KPI | Definition | Decision supported |
|---|---|---|
| Stockout days | Inventory = 0 while forecast demand > 0 | Prioritize replenishment |
| MAE | Mean absolute error between actual and forecast units | Compare error in unit terms |
| WAPE | Sum of absolute errors / sum of actual units | Compare forecast performance across groups |
| MAPE | Mean absolute percentage error where denominator is non-zero | Diagnose relative errors carefully |
| ABC class | Cumulative product sales-value contribution | Focus controls on important SKUs |
| Unit-turnover proxy | Units sold / average on-hand units | Identify slower- and faster-moving inventory |
| Revenue-exposure proxy | Forecast units on stockout days × price | Estimate availability-risk scale, not realized lost revenue |
| Reorder threshold | Average demand × (assumed lead time + safety days) | Transparent starting replenishment heuristic |

## SQL modules
- `Queries/DataLoading.sql`: schema and loading scaffold.
- `Queries/mastercard_performance_analytics.sql`: consolidated analytics covering data quality, KPI baseline, stockout exposure, rolling demand, forecast evaluation, turnover, ABC segmentation, replenishment signals, descriptive external-factor analysis, and issue prioritization.
- `Queries/abcanalysis.sql`: original ABC analysis.
- `Queries/supplier_performance.sql`: lead-time and fulfillment inference from sequential inventory observations.
- `Queries/supply.sql`: supply gaps and stockout diagnostics.
- `Queries/Indexing.sql`: indexing examples; check duplicate index definitions before rerunning.
- Remaining SQL files contain exploratory queries.

## Assumptions and limitations
- Reorder logic uses explicit assumed lead-time and safety-day values. Replace these with empirical supplier lead-time distributions and a chosen service level.
- Forecast demand × list price is an exposure proxy, not measured lost revenue. A stronger estimate must account for substitutions, partial availability, margin, and conversion.
- True inventory age requires receipt lots or inventory movements; a snapshot is insufficient.
- Inventory increases do not prove an order was received. Reliable supplier lead time and OTIF require purchase-order and goods-received timestamps.
- Weather/promotion group differences are descriptive, not causal.
- The loader contains a local CSV path and syntax that may need environment-specific adaptation. Test before assuming all scripts run unchanged.

## Suggested dashboard
1. Executive scorecard: units sold, stockout days, WAPE, estimated exposure.
2. Availability risk: SKU-store stockout heatmap and top exposure contributors.
3. Forecast diagnostics: MAE/WAPE by store, category, and week.
4. Capital efficiency: ABC classes and turnover proxy.
5. Action queue: P1/P2/P3 issues, investigation recommendation, and owner.

## Run
1. Use MySQL 8.0+.
2. Load a valid CSV and create normalized tables; update file paths/schema for your environment.
3. Validate date coverage, row counts, discounts, nulls, duplicate grain, and join coverage.
4. Execute `Queries/mastercard_performance_analytics.sql`.
5. Export results to a dashboard and document period, metric definitions, and caveats.

## Resume positioning
Highlight structured problem-solving, SQL analytics, KPI design, demand-pattern analysis, and translating data into recommendations. Add numerical scale and impact only after a reproducible run with documented data and evaluation.
