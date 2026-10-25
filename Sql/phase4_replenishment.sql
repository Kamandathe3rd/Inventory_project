-- =====================================================
-- Inventory & Order Management System
-- Phase 4: Stock replenishment & automation
-- =====================================================

USE inventory_db;

-- -----------------------------------------------------
-- Procedure: replenish_product
-- Adds stock to ONE product and records it in inventory_logs.
--   p_product_id : product to restock
--   p_quantity   : how many units arrived (must be > 0)
--   p_notes      : a note for the log (or NULL)
-- -----------------------------------------------------
DELIMITER $$

CREATE PROCEDURE replenish_product(IN p_product_id INT,
                                   IN p_quantity   INT,
                                   IN p_notes      VARCHAR(255))
BEGIN
    DECLARE v_old_stock INT;

    -- Safety net: if anything fails, undo and show the error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- 1. The quantity must be a positive number
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Replenishment quantity must be greater than 0';
    END IF;

    START TRANSACTION;

    -- 2. Read the current stock and lock the row
    SELECT stock_quantity
      INTO v_old_stock
      FROM products
     WHERE product_id = p_product_id
       FOR UPDATE;

    -- 3. Stop if the product does not exist
    IF v_old_stock IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Product does not exist';
    END IF;

    -- 4. Add the new stock
    UPDATE products
       SET stock_quantity = stock_quantity + p_quantity
     WHERE product_id = p_product_id;

    -- 5. Record the replenishment in the log
    INSERT INTO inventory_logs
        (product_id, change_type, quantity_change, stock_before, stock_after, notes)
    VALUES
        (p_product_id, 'REPLENISHMENT', p_quantity, v_old_stock, v_old_stock + p_quantity,
         COALESCE(p_notes, 'Manual replenishment'));

    COMMIT;

    -- 6. Show the updated product
    SELECT product_id, product_name, stock_quantity, reorder_level
      FROM products
     WHERE product_id = p_product_id;
END$$

DELIMITER ;


-- -----------------------------------------------------
-- Procedure: replenish_low_stock
-- Finds EVERY product below its reorder level, refills it
-- to 2 x reorder level, and logs each replenishment.
-- Safe to run many times (does nothing if nothing is low).
-- -----------------------------------------------------
DELIMITER $$

CREATE PROCEDURE replenish_low_stock()
BEGIN
    DECLARE v_first_log_id       INT;
    DECLARE v_products_restocked INT;

    -- Safety net: if anything fails, undo and show the error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- 1. FIRST write one log row per low product (uses the OLD stock)
    INSERT INTO inventory_logs
        (product_id, change_type, quantity_change, stock_before, stock_after, notes)
    SELECT  product_id,
            'REPLENISHMENT',
            (reorder_level * 2) - stock_quantity,
            stock_quantity,
            reorder_level * 2,
            'Automatic replenishment: stock was below reorder level'
    FROM products
    WHERE stock_quantity < reorder_level;

    -- 2. Remember how many were restocked and where this batch starts in the log
    SET v_products_restocked = ROW_COUNT();
    SET v_first_log_id       = LAST_INSERT_ID();

    -- 3. THEN refill the stock
    UPDATE products
       SET stock_quantity = reorder_level * 2
     WHERE stock_quantity < reorder_level;

    COMMIT;

    -- 4. Show the result
    IF v_products_restocked = 0 THEN
        SELECT 'No products need replenishment' AS message;
    ELSE
        SELECT  l.log_id,
                p.product_name,
                l.stock_before,
                l.quantity_change AS units_added,
                l.stock_after,
                p.reorder_level
        FROM inventory_logs AS l
        JOIN products AS p ON p.product_id = l.product_id
        WHERE l.log_id >= v_first_log_id
          AND l.change_type = 'REPLENISHMENT'
        ORDER BY l.log_id;
    END IF;
END$$

DELIMITER ;


-- -----------------------------------------------------
-- Procedure: refresh_customer_tier
-- Recalculates ONE customer's tier from their total spending.
-- Tier rules: Gold >= 5000, Silver >= 1500, Bronze < 1500
-- Called automatically by trg_orders_after_update.
-- (No transaction / no SELECT output, because it runs inside a trigger.)
-- -----------------------------------------------------
DELIMITER $$

CREATE PROCEDURE refresh_customer_tier(IN p_customer_id INT)
BEGIN
    DECLARE v_total_spent DECIMAL(12,2);

    -- 1. Add up everything this customer has spent
    SELECT COALESCE(SUM(total_amount), 0)
      INTO v_total_spent
      FROM orders
     WHERE customer_id = p_customer_id;

    -- 2. Set the tier from the total
    UPDATE customers
       SET customer_tier = CASE
                               WHEN v_total_spent >= 5000 THEN 'Gold'
                               WHEN v_total_spent >= 1500 THEN 'Silver'
                               ELSE 'Bronze'
                           END
     WHERE customer_id = p_customer_id;
END$$

DELIMITER ;

-- -----------------------------------------------------
-- Trigger 3: AFTER an order's total changes
-- Automatically recalculates that customer's tier.
-- (Trigger 2 updates orders.total_amount, so this fires after every order line.)
-- -----------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_orders_after_update
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
    -- Only do the work if the total actually changed
    IF NEW.total_amount <> OLD.total_amount THEN
        CALL refresh_customer_tier(NEW.customer_id);
    END IF;
END$$

DELIMITER ;

-- =====================================================
-- SECTION 4: Demonstration - replenishment
-- =====================================================

-- 4a. Low-stock products BEFORE replenishment
--     (expected: 27-inch Monitor, Standing Desk, HDMI Cable)
SELECT product_id, product_name, stock_quantity, reorder_level,
       (reorder_level * 2) - stock_quantity AS will_add
FROM products
WHERE stock_quantity < reorder_level;

-- 4b. A supplier delivers 6 Standing Desks           (expected stock 4 -> 10)
CALL replenish_product(6, 6, 'Restocked from supplier');

-- 4c. Restock everything else that is low in ONE command
--     (expected: Monitor 7 -> 20, HDMI Cable 35 -> 80)
CALL replenish_low_stock();

-- 4d. Run it again - nothing left to do
--     (expected: 'No products need replenishment')
CALL replenish_low_stock();

-- 4e. Low-stock products AFTER replenishment (expected: no rows)
SELECT product_id, product_name, stock_quantity, reorder_level
FROM products
WHERE stock_quantity < reorder_level;

-- 4f. Full replenishment history from the inventory log
SELECT  l.log_id,
        l.changed_at,
        p.product_name,
        l.quantity_change AS units_added,
        l.stock_before,
        l.stock_after,
        l.notes
FROM inventory_logs AS l
JOIN products AS p ON p.product_id = l.product_id
WHERE l.change_type = 'REPLENISHMENT'
ORDER BY l.log_id;


-- =====================================================
-- SECTION 5: Demonstration - automatic customer tiers
-- =====================================================

-- 5a. Tiers BEFORE (expected: David Gold, Levy Bronze, Molo Silver,
--                            Vedaste Bronze, Prince Silver)
SELECT customer_id, first_name, last_name, customer_tier
FROM customers
ORDER BY customer_id;

-- 5b. Vedaste buys 2 Desk Lamps (440.00) -> total 440.00 -> stays Bronze
CALL place_order(4, '[{"product_id": 9, "quantity": 2}]');

-- 5c. Levy buys a Monitor (1800.00) -> total 2681.13 -> Bronze becomes Silver
CALL place_order(2, '[{"product_id": 4, "quantity": 1}]');

-- 5d. Tiers AFTER - updated automatically, compared with actual spending
SELECT  c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer,
        COALESCE(SUM(o.total_amount), 0)       AS total_spent,
        c.customer_tier
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.first_name, c.last_name, c.customer_tier
ORDER BY total_spent DESC;


-- =====================================================
-- SECTION 6: Failure tests (each one SHOULD fail)
-- Run these ONE AT A TIME with Ctrl + Enter.
-- =====================================================

-- Test 1: restock a product that does not exist
-- Expected: Error 1644 'Product does not exist'
CALL replenish_product(999, 5, NULL);

-- Test 2: restock with zero quantity
-- Expected: Error 1644 'Replenishment quantity must be greater than 0'
CALL replenish_product(6, 0, NULL);

-- Test 3: restock with a negative quantity (would secretly remove stock)
-- Expected: Error 1644 'Replenishment quantity must be greater than 0'
CALL replenish_product(6, -5, NULL);

-- Test 4: failed order must NOT change the tier
-- (Laptop would make Vedaste Silver, but 100 Standing Desks are not in stock)
-- Expected: Error 1644 'Not enough stock for this product'
CALL place_order(4, '[{"product_id": 1, "quantity": 1},
                      {"product_id": 6, "quantity": 100}]');

-- Proof that nothing changed after the failed tests
-- Expected: Vedaste still Bronze, Standing Desk still 10, Laptop still 14
SELECT first_name, customer_tier FROM customers WHERE customer_id = 4;
SELECT product_name, stock_quantity FROM products WHERE product_id IN (1, 6);

