# SQL query guide

Use MySQL 8.0+ for the CTEs and window functions. Validate the source schema and data grain before interpreting results.

- `DataLoading.sql`: schema and loading scaffold (local path/syntax may need adaptation).
- `mastercard_performance_analytics.sql`: integrated KPI pack for data quality, stockouts, forecast errors, rolling demand, turnover, ABC classes, replenishment heuristics, and issue prioritization.
- `abcanalysis.sql`: original ABC segmentation.
- `supplier_performance.sql`: inferred lead time/fulfillment proxy; true supplier KPIs require purchase-order and receipt events.
- `supply.sql`: demand-supply gap and stockout diagnostics.
- `Indexing.sql`: check existing indexes before rerunning.
- `extra.sql`: exploratory queries; several depend on tables not created by the normalized loader.

Before publishing, record data period, SKU/store counts, table row counts, join coverage, null/duplicate checks, and metric definitions.
