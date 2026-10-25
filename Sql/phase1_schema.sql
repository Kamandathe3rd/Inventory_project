-- =====================================================
-- Inventory & Order Management System
-- Phase 1: Database Schema
-- Author: David Kamanda
-- =====================================================

-- Fresh start: remove the old database and create a new one
DROP DATABASE IF EXISTS inventory_db;
CREATE DATABASE inventory_db;
USE inventory_db;

-- -----------------------------------------------------
-- Table 1: products
-- -----------------------------------------------------
CREATE TABLE products (
    product_id      INT AUTO_INCREMENT PRIMARY KEY,
    product_name    VARCHAR(100)  NOT NULL,
    category        VARCHAR(50)   NOT NULL,
    price           DECIMAL(10,2) NOT NULL,
    stock_quantity  INT           NOT NULL DEFAULT 0,
    reorder_level   INT           NOT NULL DEFAULT 10
);

-- Data rules for products
ALTER TABLE products
    ADD CONSTRAINT chk_price       CHECK (price >= 0),
    ADD CONSTRAINT chk_stock       CHECK (stock_quantity >= 0),
    ADD CONSTRAINT chk_reorder     CHECK (reorder_level >= 0),
    ADD CONSTRAINT uq_product_name UNIQUE (product_name);

-- -----------------------------------------------------
-- Table 2: customers
-- customer_tier is updated automatically in Phase 4
-- -----------------------------------------------------
CREATE TABLE customers (
    customer_id     INT AUTO_INCREMENT PRIMARY KEY,
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(100) NOT NULL UNIQUE,
    phone           VARCHAR(20),
    customer_tier   ENUM('Bronze','Silver','Gold') NOT NULL DEFAULT 'Bronze'
);

-- -----------------------------------------------------
-- Table 3: orders (one row per order)
-- Each order must belong to a real customer
-- -----------------------------------------------------
CREATE TABLE orders (
    order_id      INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT           NOT NULL,
    order_date    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_amount  DECIMAL(12,2) NOT NULL DEFAULT 0.00,

    CONSTRAINT chk_total CHECK (total_amount >= 0),

    CONSTRAINT fk_orders_customer
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);

-- -----------------------------------------------------
-- Table 4: order_details (one row per product in an order)
-- unit_price is a snapshot of the price at the time of sale
-- unit_price and line_total are filled by a trigger in Phase 2
-- -----------------------------------------------------
CREATE TABLE order_details (
    order_detail_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id        INT           NOT NULL,
    product_id      INT           NOT NULL,
    quantity        INT           NOT NULL,
    unit_price      DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    discount_pct    DECIMAL(5,2)  NOT NULL DEFAULT 0.00,
    line_total      DECIMAL(12,2) NOT NULL DEFAULT 0.00,

    CONSTRAINT chk_quantity     CHECK (quantity > 0),
    CONSTRAINT chk_unit_price   CHECK (unit_price >= 0),
    CONSTRAINT chk_discount     CHECK (discount_pct BETWEEN 0 AND 100),
    CONSTRAINT uq_order_product UNIQUE (order_id, product_id),

    CONSTRAINT fk_details_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_details_product
        FOREIGN KEY (product_id) REFERENCES products (product_id)
);

-- -----------------------------------------------------
-- Table 5: inventory_logs (audit history of every stock change)
-- negative quantity_change = stock out, positive = stock in
-- -----------------------------------------------------
CREATE TABLE inventory_logs (
    log_id          INT AUTO_INCREMENT PRIMARY KEY,
    product_id      INT          NOT NULL,
    change_type     ENUM('ORDER','REPLENISHMENT','ADJUSTMENT') NOT NULL,
    quantity_change INT          NOT NULL,
    stock_before    INT          NOT NULL,
    stock_after     INT          NOT NULL,
    order_id        INT          NULL,
    notes           VARCHAR(255),
    changed_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_change_not_zero CHECK (quantity_change <> 0),

    CONSTRAINT fk_logs_product
        FOREIGN KEY (product_id) REFERENCES products (product_id),

    CONSTRAINT fk_logs_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON DELETE SET NULL
);

-- -----------------------------------------------------
-- Indexes for performance
-- (primary keys, unique columns and foreign keys are indexed automatically)
-- -----------------------------------------------------
CREATE INDEX idx_products_category ON products (category);
CREATE INDEX idx_products_stock    ON products (stock_quantity, reorder_level);
CREATE INDEX idx_orders_cust_date  ON orders (customer_id, order_date);
CREATE INDEX idx_orders_date       ON orders (order_date);
CREATE INDEX idx_logs_product_date ON inventory_logs (product_id, changed_at);
CREATE INDEX idx_logs_type         ON inventory_logs (change_type);