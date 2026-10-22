-- =====================================================
-- Inventory & Order Management System
-- Phase 3: Monitoring & reporting
-- Author: David Kamanda
-- =====================================================

USE inventory_db;

-- -----------------------------------------------------
-- Report 1: Order summary - every order, grouped by customer
-- -----------------------------------------------------
SELECT  CONCAT(c.first_name, ' ', c.last_name) AS customer,
        o.order_id,
        o.order_date,
        COUNT(od.order_detail_id) AS products_in_order,
        SUM(od.quantity)          AS items,
        o.total_amount
FROM customers AS c
JOIN orders        AS o  ON o.customer_id = c.customer_id
JOIN order_details AS od ON od.order_id   = o.order_id
GROUP BY c.customer_id, c.first_name, c.last_name,
         o.order_id, o.order_date, o.total_amount
ORDER BY customer, o.order_id;

-- -----------------------------------------------------
-- Report 2: Customer summary - one row per customer
-- (LEFT JOIN keeps customers with no orders)
-- -----------------------------------------------------
SELECT  CONCAT(c.first_name, ' ', c.last_name)    AS customer,
        COUNT(o.order_id)                         AS number_of_orders,
        COALESCE(SUM(o.total_amount), 0)          AS total_spent,
        COALESCE(ROUND(AVG(o.total_amount), 2), 0) AS average_order,
        MIN(o.order_date)                         AS first_order,
        MAX(o.order_date)                         AS last_order
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.first_name, c.last_name
ORDER BY total_spent DESC;

-- -----------------------------------------------------
-- Report 3: Low-stock report - products below their reorder level
-- Rule: suggested order refills stock to 2 x reorder level
-- -----------------------------------------------------
SELECT  product_id,
        product_name,
        category,
        stock_quantity,
        reorder_level,
        reorder_level - stock_quantity                   AS shortfall,
        (reorder_level * 2) - stock_quantity             AS suggested_order_qty,
        ((reorder_level * 2) - stock_quantity) * price   AS estimated_cost
FROM products
WHERE stock_quantity < reorder_level
ORDER BY shortfall DESC;

-- Total cost to restock all low products
SELECT  COUNT(*)                                            AS products_to_reorder,
        SUM((reorder_level * 2) - stock_quantity)           AS total_units_to_order,
        SUM(((reorder_level * 2) - stock_quantity) * price) AS total_estimated_cost
FROM products
WHERE stock_quantity < reorder_level;

-- -----------------------------------------------------
-- Report 4: Stock status dashboard - every product with a status label
-- -----------------------------------------------------
SELECT  product_id,
        product_name,
        category,
        stock_quantity,
        reorder_level,
        CASE
            WHEN stock_quantity = 0              THEN 'OUT OF STOCK'
            WHEN stock_quantity < reorder_level  THEN 'REORDER NOW'
            ELSE 'OK'
        END AS stock_status
FROM products
ORDER BY stock_quantity - reorder_level, product_name;

-- Summary: how many products in each status
SELECT  CASE
            WHEN stock_quantity = 0              THEN 'OUT OF STOCK'
            WHEN stock_quantity < reorder_level  THEN 'REORDER NOW'
            ELSE 'OK'
        END AS stock_status,
        COUNT(*) AS number_of_products
FROM products
GROUP BY stock_status;

-- -----------------------------------------------------
-- Report 5: Customer spending report with tiers
-- Tier rules: Gold >= 5000, Silver >= 1500, Bronze < 1500
-- -----------------------------------------------------
SELECT  customer,
        number_of_orders,
        total_spent,
        CASE
            WHEN total_spent >= 5000 THEN 'Gold'
            WHEN total_spent >= 1500 THEN 'Silver'
            ELSE 'Bronze'
        END AS calculated_tier,
        CASE
            WHEN total_spent >= 5000 THEN 0
            WHEN total_spent >= 1500 THEN 5000 - total_spent
            ELSE 1500 - total_spent
        END AS needed_for_next_tier,
        stored_tier
FROM (
    SELECT  c.customer_id,
            CONCAT(c.first_name, ' ', c.last_name) AS customer,
            COUNT(o.order_id)                      AS number_of_orders,
            COALESCE(SUM(o.total_amount), 0)       AS total_spent,
            c.customer_tier                        AS stored_tier
    FROM customers AS c
    LEFT JOIN orders AS o ON o.customer_id = c.customer_id
    GROUP BY c.customer_id, c.first_name, c.last_name, c.customer_tier
) AS spending
ORDER BY total_spent DESC;

-- -----------------------------------------------------
-- Report 6: Tier summary - customers and revenue per tier
-- -----------------------------------------------------
SELECT  tier,
        COUNT(*)          AS customers,
        SUM(total_spent)  AS tier_revenue,
        ROUND(SUM(total_spent) * 100 / (SELECT SUM(total_amount) FROM orders), 2)
                          AS percent_of_revenue
FROM (
    SELECT  c.customer_id,
            COALESCE(SUM(o.total_amount), 0) AS total_spent,
            CASE
                WHEN COALESCE(SUM(o.total_amount), 0) >= 5000 THEN 'Gold'
                WHEN COALESCE(SUM(o.total_amount), 0) >= 1500 THEN 'Silver'
                ELSE 'Bronze'
            END AS tier
    FROM customers AS c
    LEFT JOIN orders AS o ON o.customer_id = c.customer_id
    GROUP BY c.customer_id
) AS customer_tiers
GROUP BY tier
ORDER BY tier_revenue DESC;

SET SQL_SAFE_UPDATES = 0;

-- -----------------------------------------------------
-- Categorize customers: save each customer's tier
-- (Phase 4 will make this happen automatically after every order)
-- -----------------------------------------------------
UPDATE customers AS c
LEFT JOIN (
    SELECT customer_id, SUM(total_amount) AS total_spent
    FROM orders
    GROUP BY customer_id
) AS s ON s.customer_id = c.customer_id
SET c.customer_tier = CASE
                          WHEN COALESCE(s.total_spent, 0) >= 5000 THEN 'Gold'
                          WHEN COALESCE(s.total_spent, 0) >= 1500 THEN 'Silver'
                          ELSE 'Bronze'
                      END;

SELECT customer_id, first_name, last_name, customer_tier
FROM customers;

-- -----------------------------------------------------
-- Report 7: Bulk discounts applied - order lines with a discount
-- Discount rule: 20-49 units = 5%, 50+ units = 10%
-- -----------------------------------------------------
SELECT  o.order_id,
        CONCAT(c.first_name, ' ', c.last_name)   AS customer,
        p.product_name,
        od.quantity,
        od.unit_price,
        od.quantity * od.unit_price              AS gross_amount,
        od.discount_pct,
        od.quantity * od.unit_price - od.line_total AS discount_amount,
        od.line_total                            AS net_amount
FROM order_details AS od
JOIN orders    AS o ON o.order_id    = od.order_id
JOIN customers AS c ON c.customer_id = o.customer_id
JOIN products  AS p ON p.product_id  = od.product_id
WHERE od.discount_pct > 0
ORDER BY discount_amount DESC;

-- -----------------------------------------------------
-- Report 8: Discounts per customer (gross, discount, net)
-- -----------------------------------------------------
SELECT  CONCAT(c.first_name, ' ', c.last_name)                       AS customer,
        c.customer_tier,
        COUNT(DISTINCT o.order_id)                                   AS number_of_orders,
        COALESCE(SUM(od.quantity * od.unit_price), 0)                AS gross_amount,
        COALESCE(SUM(od.quantity * od.unit_price - od.line_total), 0) AS total_discount,
        COALESCE(SUM(od.line_total), 0)                              AS net_paid
FROM customers AS c
LEFT JOIN orders        AS o  ON o.customer_id = c.customer_id
LEFT JOIN order_details AS od ON od.order_id   = o.order_id
GROUP BY c.customer_id, c.first_name, c.last_name, c.customer_tier
ORDER BY total_discount DESC, net_paid DESC;

-- -----------------------------------------------------
-- Report 9: Discount summary by discount level
-- -----------------------------------------------------
SELECT  CASE
            WHEN discount_pct = 10 THEN '10% (50+ units)'
            WHEN discount_pct = 5  THEN '5% (20-49 units)'
            ELSE 'No discount (1-19 units)'
        END                                         AS discount_level,
        COUNT(*)                                    AS order_lines,
        SUM(quantity)                               AS units_sold,
        SUM(quantity * unit_price)                  AS gross_amount,
        SUM(quantity * unit_price - line_total)     AS discount_given,
        SUM(line_total)                             AS net_revenue
FROM order_details
GROUP BY discount_pct
ORDER BY discount_pct DESC;

-- Overall: total discount given as a share of gross sales
SELECT  SUM(quantity * unit_price)                AS gross_sales,
        SUM(quantity * unit_price - line_total)   AS total_discount,
        SUM(line_total)                           AS net_sales,
        ROUND(SUM(quantity * unit_price - line_total) * 100
              / SUM(quantity * unit_price), 2)    AS discount_percent
FROM order_details;