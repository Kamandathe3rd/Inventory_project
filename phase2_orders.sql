-- =====================================================
-- Inventory & Order Management System
-- Phase 2: Order placement & inventory tracking
-- =====================================================

USE inventory_db;

-- -----------------------------------------------------
-- Sample data: products
-- (Monitor, Standing Desk and HDMI Cable start below reorder level)
-- -----------------------------------------------------
INSERT INTO products (product_name, category, price, stock_quantity, reorder_level) VALUES
('Laptop',          'Electronics', 4500.00,   15,   5),
('Wireless Mouse',  'Electronics',   85.00,  120,  30),
('USB Keyboard',    'Electronics',  150.00,   60,  20),
('27-inch Monitor', 'Electronics', 1800.00,    8,  10),
('Office Chair',    'Furniture',   1200.00,   25,  10),
('Standing Desk',   'Furniture',   2500.00,    4,   5),
('Notebook A4',     'Stationery',    12.00,  500, 100),
('Ballpoint Pen',   'Stationery',     3.50, 1000, 200),
('Desk Lamp',       'Furniture',    220.00,   18,  10),
('HDMI Cable',      'Electronics',   45.00,   35,  40);
SELECT * FROM products;

-- -----------------------------------------------------
-- Sample data: customers (all start as Bronze)
-- -----------------------------------------------------
INSERT INTO customers (first_name, last_name, email, phone) VALUES
('David',    'Kamanda',     'David.kamnda@amalitech.com',     '0241234567'),
('Levy',     'Imanzi',      'Levy.Imanzi@amalitech.com',      '0209876543'),
('Molo',     'Munyansanga', 'Molo.Munyansaga@amalitech.com',  '0277654321'),
('Vedaste',  'Mugabo',      'Vedaste.Mugabo@amalitech.com',   NULL),
('Prince',   'Dushimimana', 'Prince.Dushimimana@example.com', '0501112233');
SELECT * FROM customers;

SELECT product_name, stock_quantity, reorder_level
FROM products
WHERE stock_quantity < reorder_level;

-- -----------------------------------------------------
-- Trigger 1: BEFORE a line is added to an order
--  - checks there is enough stock
--  - copies the current price
--  - applies a bulk discount (20+ = 5%, 50+ = 10%)
--  - calculates the line total
-- -----------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_order_details_before_insert
BEFORE INSERT ON order_details
FOR EACH ROW
BEGIN
    -- 1. Create two variables (temporary boxes)
    DECLARE v_price DECIMAL(10,2);
    DECLARE v_stock INT;

    -- 2. Look up this product's price and stock
    SELECT price, stock_quantity
      INTO v_price, v_stock
      FROM products
     WHERE product_id = NEW.product_id;

    -- 3. Stop if there is not enough stock
    IF v_stock < NEW.quantity THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Not enough stock for this product';
    END IF;

    -- 4. Copy the current price into the order line
    SET NEW.unit_price = v_price;

    -- 5. Work out the bulk discount
    IF NEW.quantity >= 50 THEN
        SET NEW.discount_pct = 10.00;
    ELSEIF NEW.quantity >= 20 THEN
        SET NEW.discount_pct = 5.00;
    ELSE
        SET NEW.discount_pct = 0.00;
    END IF;

    -- 6. Line total = quantity x price x (1 - discount/100), rounded to 2 decimals
    SET NEW.line_total = ROUND(NEW.quantity * NEW.unit_price * (1 - NEW.discount_pct / 100), 2);
END$$

DELIMITER ;
SHOW TRIGGERS;

-- -----------------------------------------------------
-- Trigger 2: AFTER a line is added to an order
--  - deducts the stock
--  - writes the change to inventory_logs
--  - adds the line total to the order total
-- -----------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_order_details_after_insert
AFTER INSERT ON order_details
FOR EACH ROW
BEGIN
    -- A variable to remember the stock level before the change
    DECLARE v_old_stock INT;

    -- 1. Remember the current stock
    SELECT stock_quantity
      INTO v_old_stock
      FROM products
     WHERE product_id = NEW.product_id;

    -- 2. Deduct the quantity ordered from stock
    UPDATE products
       SET stock_quantity = stock_quantity - NEW.quantity
     WHERE product_id = NEW.product_id;

    -- 3. Record the change in the inventory log
    INSERT INTO inventory_logs
        (product_id, change_type, quantity_change, stock_before, stock_after, order_id, notes)
    VALUES
        (NEW.product_id, 'ORDER', -NEW.quantity, v_old_stock, v_old_stock - NEW.quantity,
         NEW.order_id, 'Stock deducted for order');

    -- 4. Add this line's total to the order's total
    UPDATE orders
       SET total_amount = total_amount + NEW.line_total
     WHERE order_id = NEW.order_id;
END$$

DELIMITER ;
SHOW TRIGGERS;

-- -----------------------------------------------------
-- Procedure: place_order
-- Places a whole order in ONE command (all or nothing).
-- p_customer_id : the customer placing the order
-- p_items       : JSON list of products, e.g.
--                 '[{"product_id": 1, "quantity": 2}, {"product_id": 3, "quantity": 1}]'
-- The triggers handle price, discount, stock, log and total.
-- -----------------------------------------------------
DELIMITER $$

CREATE PROCEDURE place_order(IN p_customer_id INT, IN p_items JSON)
BEGIN
    DECLARE v_order_id INT;

    -- Safety net: if ANY error happens, undo everything and show the error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- 1. Create the order header
    INSERT INTO orders (customer_id) VALUES (p_customer_id);
    SET v_order_id = LAST_INSERT_ID();

    -- 2. Turn the JSON list into rows and add them as order lines
    INSERT INTO order_details (order_id, product_id, quantity)
    SELECT v_order_id, items.product_id, items.quantity
      FROM JSON_TABLE(
             p_items, '$[*]'
             COLUMNS (
                 product_id INT PATH '$.product_id',
                 quantity   INT PATH '$.quantity'
             )
           ) AS items;

    -- 3. Everything worked: save it all
    COMMIT;

    -- 4. Show the finished order
    SELECT * FROM orders WHERE order_id = v_order_id;
END$$

DELIMITER ;

-- =====================================================
--  Place sample orders
-- =====================================================

-- Order 1: David - 1 Laptop + 2 Wireless Mice                 (expected total 4670.00)
CALL place_order(1, '[{"product_id": 1, "quantity": 1},
                      {"product_id": 2, "quantity": 2}]');

-- Order 2: Levy - bulk order, tests both discount levels     (expected total 881.13)
CALL place_order(2, '[{"product_id": 7, "quantity": 60},
                      {"product_id": 8, "quantity": 25},
                      {"product_id": 3, "quantity": 1}]');

-- Order 3: Molo - 2 Office Chairs                             (expected total 2400.00)
CALL place_order(3, '[{"product_id": 5, "quantity": 2}]');

-- Order 4: Prince - 1 Office Chair + 2 Desk Lamps            (expected total 1640.00)
CALL place_order(5, '[{"product_id": 5, "quantity": 1},
                      {"product_id": 9, "quantity": 2}]');

-- Order 5: David again - 1 Monitor                             (expected total 1800.00)
CALL place_order(1, '[{"product_id": 4, "quantity": 1}]');

-- (Vedaste, customer 4, deliberately has no orders - used in Phase 3 reports)


-- =====================================================
--  Inventory tracking queries
-- =====================================================

--  Current stock levels
SELECT product_id, product_name, stock_quantity, reorder_level
FROM products
ORDER BY product_id;

-- Full inventory history (audit trail), newest first
SELECT  l.log_id,
        l.changed_at,
        p.product_name,
        l.change_type,
        l.quantity_change,
        l.stock_before,
        l.stock_after,
        l.order_id
FROM inventory_logs AS l
JOIN products AS p ON p.product_id = l.product_id
ORDER BY l.changed_at DESC, l.log_id DESC;

-- History of a single product (Office Chair = 5)
SELECT  l.changed_at,
        p.product_name,
        l.change_type,
        l.quantity_change,
        l.stock_before,
        l.stock_after,
        l.order_id
FROM inventory_logs AS l
JOIN products AS p ON p.product_id = l.product_id
WHERE l.product_id = 5
ORDER BY l.changed_at, l.log_id;

-- Stock used per order
SELECT  o.order_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer,
        o.order_date,
        COUNT(od.product_id) AS different_products,
        SUM(od.quantity)     AS total_units_used,
        o.total_amount
FROM orders AS o
JOIN customers     AS c  ON c.customer_id = o.customer_id
JOIN order_details AS od ON od.order_id   = o.order_id
GROUP BY o.order_id, c.first_name, c.last_name, o.order_date, o.total_amount
ORDER BY o.order_id;

-- Order lines with prices and discounts
SELECT  od.order_id,
        p.product_name,
        od.quantity,
        od.unit_price,
        od.discount_pct,
        od.line_total
FROM order_details AS od
JOIN products AS p ON p.product_id = od.product_id
ORDER BY od.order_id, od.order_detail_id;


-- =====================================================
-- Failure tests (each one SHOULD fail)

-- Run these ONE AT A TIME with Ctrl + Enter.
-- After each one, nothing should change: no new order,
-- no stock change, no new log row.
-- =====================================================

-- Test 1: one product out of stock -> whole order rolled back
-- Expected: Error 1644 'Not enough stock for this product'
CALL place_order(4, '[{"product_id": 9, "quantity": 1},
                      {"product_id": 6, "quantity": 100}]');

-- Test 2: customer does not exist
-- Expected: Error 1452 foreign key constraint fails
CALL place_order(99, '[{"product_id": 1, "quantity": 1}]');

-- Test 3: product does not exist
-- Expected: Error 1644 'Product does not exist'
CALL place_order(4, '[{"product_id": 9, "quantity": 1},
                      {"product_id": 999, "quantity": 1}]');

-- Test 4: quantity of zero
-- Expected: Error 3819 check constraint 'chk_quantity' is violated
CALL place_order(4, '[{"product_id": 9, "quantity": 0}]');

-- Proof that nothing changed after the failed tests
-- Expected: 5 orders, 9 log rows, Desk Lamp stock = 16, Standing Desk stock = 4
SELECT COUNT(*) AS orders_count FROM orders;
SELECT COUNT(*) AS log_rows     FROM inventory_logs;
SELECT product_name, stock_quantity FROM products WHERE product_id IN (6, 9);