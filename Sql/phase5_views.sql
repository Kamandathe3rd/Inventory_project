-- =====================================================
-- Inventory & Order Management System
-- Phase 5: Views & performance optimization
-- =====================================================

USE inventory_db;

-- -----------------------------------------------------
-- View 1: vw_order_summary
-- One row per order: customer name, order date, total amount,
-- number of different products and number of items.
-- -----------------------------------------------------
CREATE OR REPLACE VIEW vw_order_summary AS
SELECT  o.order_id,
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        c.customer_tier,
        o.order_date,
        COUNT(od.order_detail_id)              AS number_of_products,
        COALESCE(SUM(od.quantity), 0)          AS number_of_items,
        o.total_amount
FROM orders AS o
JOIN customers          AS c  ON c.customer_id = o.customer_id
LEFT JOIN order_details AS od ON od.order_id   = o.order_id
GROUP BY o.order_id, c.customer_id, c.first_name, c.last_name,
         c.customer_tier, o.order_date, o.total_amount;
         
         SELECT * FROM vw_order_summary
ORDER BY order_id;

SELECT order_id, order_date, number_of_items, total_amount
FROM vw_order_summary
WHERE customer_name = 'Levy Imanzi';

SELECT  customer_name,
        COUNT(*)              AS orders,
        SUM(number_of_items)  AS items_bought,
        SUM(total_amount)     AS total_spent
FROM vw_order_summary
GROUP BY customer_name
ORDER BY total_spent DESC;

SHOW FULL TABLES WHERE Table_type = 'VIEW';

-- -----------------------------------------------------
-- View 2: vw_low_stock
-- Products below their reorder level that need to be reordered,
-- with the shortfall, suggested order quantity and estimated cost.
-- Rule: refill to 2 x reorder level (same as Phase 3 and Phase 4).
-- -----------------------------------------------------
CREATE OR REPLACE VIEW vw_low_stock AS
SELECT  product_id,
        product_name,
        category,
        price,
        stock_quantity,
        reorder_level,
        reorder_level - stock_quantity                  AS shortfall,
        (reorder_level * 2) - stock_quantity            AS suggested_order_qty,
        ((reorder_level * 2) - stock_quantity) * price  AS estimated_cost,
        CASE
            WHEN stock_quantity = 0 THEN 'OUT OF STOCK'
            ELSE 'REORDER NOW'
        END                                             AS stock_status
FROM products
WHERE is_low_stock = 1;


-- -----------------------------------------------------
-- Bonus view: vw_customer_spending
-- One row per customer (including customers with no orders):
-- number of orders, total spent, average order, last order date, tier.
-- -----------------------------------------------------
CREATE OR REPLACE VIEW vw_customer_spending AS
SELECT  c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name)     AS customer_name,
        c.email,
        COUNT(o.order_id)                          AS number_of_orders,
        COALESCE(SUM(o.total_amount), 0)           AS total_spent,
        COALESCE(ROUND(AVG(o.total_amount), 2), 0) AS average_order,
        MAX(o.order_date)                          AS last_order_date,
        c.customer_tier
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.first_name, c.last_name, c.email, c.customer_tier;

-- List all views
SHOW FULL TABLES WHERE Table_type = 'VIEW';


-- =====================================================
--  Using the views
-- =====================================================

-- 3a. Every order
SELECT * FROM vw_order_summary ORDER BY order_id;

-- 3b. One customer's orders
SELECT order_id, order_date, number_of_items, total_amount
FROM vw_order_summary
WHERE customer_name = 'Levy Imanzi';

-- 3c. Customer spending, biggest first
SELECT * FROM vw_customer_spending ORDER BY total_spent DESC;

-- 3d. Revenue per tier
SELECT customer_tier, COUNT(*) AS customers, SUM(total_spent) AS revenue
FROM vw_customer_spending
GROUP BY customer_tier
ORDER BY revenue DESC;


-- =====================================================
--  Replenishment demonstration (Phases 2, 4 and 5 together)
-- =====================================================

-- 4a. Nothing is low after Phase 4 (expected: no rows)
SELECT * FROM vw_low_stock;

-- 4b. Molo buys 5 Desk Lamps: stock 14 -> 9, below reorder level 10
CALL place_order(3, '[{"product_id": 9, "quantity": 5}]');

-- 4c. The Desk Lamp now appears in the view automatically
--     (expected: shortfall 1, suggested_order_qty 11, estimated_cost 2420.00)
SELECT product_name, stock_quantity, reorder_level, is_low_stock FROM products WHERE product_id = 9;
SELECT * FROM vw_low_stock;

-- 4d. Restock everything that is low (expected: Desk Lamp 9 -> 20, +11)
CALL replenish_low_stock();

-- 4e. The view is empty again
SELECT * FROM vw_low_stock;

-- 4f. The full history of the Desk Lamp in the inventory log
SELECT  l.changed_at,
        l.change_type,
        l.quantity_change,
        l.stock_before,
        l.stock_after,
        l.order_id,
        l.notes
FROM inventory_logs AS l
WHERE l.product_id = 9
ORDER BY l.log_id;


-- =====================================================
--  EXPLAIN evidence on the real tables
-- (type = ref / const means an index is used)
-- =====================================================

EXPLAIN SELECT * FROM orders         WHERE customer_id = 2;
EXPLAIN SELECT * FROM order_details  WHERE order_id = 1;
EXPLAIN SELECT * FROM inventory_logs WHERE product_id = 5 ORDER BY changed_at;
EXPLAIN SELECT * FROM products       WHERE is_low_stock = 1;
EXPLAIN SELECT * FROM customers      WHERE email = 'David.Kamanda@amalitech.com';


-- =====================================================
--  Performance test at scale (200,000 rows)
--   Uses a separate practice table; real data is not touched.
--   Takes 5-20 seconds. Watch the Duration column in the Output panel.
-- =====================================================

DROP TABLE IF EXISTS perf_orders;

CREATE TABLE perf_orders (
    order_id     INT AUTO_INCREMENT PRIMARY KEY,
    customer_id  INT           NOT NULL,
    order_date   DATETIME      NOT NULL,
    total_amount DECIMAL(12,2) NOT NULL
);

SET SESSION cte_max_recursion_depth = 200000;

INSERT INTO perf_orders (customer_id, order_date, total_amount)
WITH RECURSIVE numbers (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM numbers WHERE n < 200000
)
SELECT  FLOOR(1 + RAND() * 10000),
        NOW() - INTERVAL FLOOR(RAND() * 730) DAY,
        ROUND(10 + RAND() * 5000, 2)
FROM numbers;

-- 6a. WITHOUT an index: type = ALL, about 200,000 rows read
EXPLAIN SELECT * FROM perf_orders WHERE customer_id = 1234;
SELECT COUNT(*), SUM(total_amount) FROM perf_orders WHERE customer_id = 1234;

-- 6b. WITH an index: type = ref, about 20 rows read
CREATE INDEX idx_perf_customer ON perf_orders (customer_id);
EXPLAIN SELECT * FROM perf_orders WHERE customer_id = 1234;
SELECT COUNT(*), SUM(total_amount) FROM perf_orders WHERE customer_id = 1234;

-- 6c. A function on an indexed column disables the index jump
CREATE INDEX idx_perf_date ON perf_orders (order_date);

-- Slow: type = index, about 200,000 rows read
EXPLAIN SELECT COUNT(*) FROM perf_orders
WHERE YEAR(order_date) = 2025 AND MONTH(order_date) = 3;

-- Fast: type = range, only March rows read (same answer)
EXPLAIN SELECT COUNT(*) FROM perf_orders
WHERE order_date >= '2025-03-01' AND order_date < '2025-04-01';

-- 6d. Remove the practice table
DROP TABLE perf_orders;