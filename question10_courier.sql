DROP SCHEMA public CASCADE;
CREATE SCHEMA public;




-- ============================================================
-- ICT371 - QUESTION 10: Courier Deliveries and Daily Deliveries
-- total_amount = distance_km * rate_per_km
-- ============================================================

-- ------------------------------------------------------------
-- (a) DATABASE AND SEED DATA
-- ------------------------------------------------------------
DROP TABLE IF EXISTS daily_deliveries, delivery_audit, deliveries, couriers, customers CASCADE;

CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  customer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE couriers (
  courier_id SERIAL PRIMARY KEY,
  courier_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  rate_per_km NUMERIC(8,2) NOT NULL CHECK (rate_per_km > 0)
);

CREATE TABLE deliveries (
  delivery_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id),
  courier_id INT NOT NULL REFERENCES couriers(courier_id),
  pickup_date DATE NOT NULL,
  delivery_date DATE NOT NULL,
  distance_km NUMERIC(8,2) NOT NULL CHECK (distance_km > 0),
  status VARCHAR(20) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'in_transit', 'delivered', 'cancelled')),
  total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  CHECK (delivery_date >= pickup_date)
);

CREATE TABLE delivery_audit (
  audit_id SERIAL PRIMARY KEY,
  delivery_id INT NOT NULL REFERENCES deliveries(delivery_id),
  old_status VARCHAR(20) NULL,
  new_status VARCHAR(20) NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_deliveries (
  delivery_day DATE PRIMARY KEY,
  total_deliveries INT NOT NULL DEFAULT 0,
  total_revenue NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (customer_number, full_name) VALUES
('CUS001', 'Linda Banda'),
('CUS002', 'Moses Zulu'),
('CUS003', 'Grace Mwale');

INSERT INTO couriers (courier_number, full_name, rate_per_km) VALUES
('COR001', 'John Banda', 5.00),
('COR002', 'Mary Phiri', 4.00),
('COR003', 'David Tembo', 6.00);

-- ------------------------------------------------------------
-- (b) FUNCTION
-- fn_courier_total(p_courier_id, p_start, p_end)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_courier_total(p_courier_id INT, p_start DATE, p_end DATE)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_total NUMERIC(12,2);
BEGIN
  IF p_start IS NULL OR p_end IS NULL THEN RAISE EXCEPTION 'Start and end dates are required'; END IF;
  IF p_end <= p_start THEN RAISE EXCEPTION 'End must be after start'; END IF;
  IF NOT EXISTS (SELECT 1 FROM couriers WHERE courier_id = p_courier_id) THEN
    RAISE EXCEPTION 'Unknown courier: %', p_courier_id;
  END IF;
  SELECT COALESCE(SUM(total_amount), 0) INTO v_total FROM deliveries
  WHERE courier_id = p_courier_id AND status <> 'cancelled'
    AND pickup_date >= p_start AND pickup_date < p_end;
  RETURN v_total;
END; $$;

-- ------------------------------------------------------------
-- (c) PROCEDURE
-- pr_create_delivery(p_customer_id, p_courier_id, p_pickup_date, p_delivery_date, p_distance_km)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_create_delivery(p_customer_id INT, p_courier_id INT, p_pickup_date DATE, p_delivery_date DATE, p_distance_km NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE v_rate NUMERIC(8,2);
BEGIN
  IF p_pickup_date IS NULL OR p_delivery_date IS NULL THEN RAISE EXCEPTION 'Pickup and delivery dates are required'; END IF;
  IF p_pickup_date < CURRENT_DATE THEN RAISE EXCEPTION 'Cannot pickup in the past: %', p_pickup_date; END IF;
  IF p_delivery_date < p_pickup_date THEN RAISE EXCEPTION 'Delivery date cannot be before pickup date'; END IF;
  IF p_distance_km IS NULL OR p_distance_km <= 0 THEN RAISE EXCEPTION 'Distance must be greater than 0'; END IF;
  IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
    RAISE EXCEPTION 'Unknown customer: %', p_customer_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM couriers WHERE courier_id = p_courier_id) THEN
    RAISE EXCEPTION 'Unknown courier: %', p_courier_id;
  END IF;
  IF EXISTS (SELECT 1 FROM deliveries WHERE courier_id = p_courier_id AND status IN ('pending', 'in_transit')
    AND pickup_date <= p_delivery_date AND delivery_date >= p_pickup_date) THEN
    RAISE EXCEPTION 'Courier % already has a delivery for those dates', p_courier_id;
  END IF;
  SELECT rate_per_km INTO v_rate FROM couriers WHERE courier_id = p_courier_id;
  INSERT INTO deliveries (customer_id, courier_id, pickup_date, delivery_date, distance_km, status, total_amount)
  VALUES (p_customer_id, p_courier_id, p_pickup_date, p_delivery_date, p_distance_km, 'pending', p_distance_km * v_rate);
END; $$;

-- ------------------------------------------------------------
-- (d) TRIGGER
-- AFTER UPDATE on deliveries -> delivery_audit only if status changed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_delivery_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO delivery_audit (delivery_id, old_status, new_status, changed_at)
    VALUES (NEW.delivery_id, OLD.status, NEW.status, NOW());
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_delivery_audit ON deliveries;
CREATE TRIGGER trg_delivery_audit
AFTER UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_audit_fn();

-- ------------------------------------------------------------
-- (a) CONTINUED: Seed 6 deliveries THROUGH procedure, no overlaps per courier
-- ------------------------------------------------------------
CALL pr_create_delivery(1, 1, '2026-11-25', '2026-11-25', 10.00);
CALL pr_create_delivery(2, 2, '2026-11-25', '2026-11-26', 15.00);
CALL pr_create_delivery(3, 3, '2026-11-25', '2026-11-25', 20.00);
CALL pr_create_delivery(1, 2, '2026-11-27', '2026-11-27', 12.00);
CALL pr_create_delivery(2, 1, '2026-11-26', '2026-11-26', 8.00);
CALL pr_create_delivery(3, 3, '2026-11-26', '2026-11-27', 5.00);

-- Change 2 statuses to test trigger - 1 in_transit, 1 cancelled
UPDATE deliveries SET status = 'in_transit' WHERE delivery_id = 1;
UPDATE deliveries SET status = 'cancelled' WHERE delivery_id = 2;

-- ------------------------------------------------------------
-- (e) VIEW
-- v_pending_deliveries - pending or in_transit and delivery_date >= today
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_pending_deliveries AS
SELECT d.delivery_id, c.full_name AS customer_name, co.full_name AS courier_name,
  d.pickup_date, d.delivery_date, d.distance_km, d.status, d.total_amount
FROM deliveries d
JOIN customers c ON c.customer_id = d.customer_id
JOIN couriers co ON co.courier_id = d.courier_id
WHERE d.status IN ('pending', 'in_transit') AND d.delivery_date >= CURRENT_DATE;

SELECT * FROM v_pending_deliveries;

-- ------------------------------------------------------------
-- (f) INDEX
-- For a courier's deliveries within a date range
-- ------------------------------------------------------------
CREATE INDEX idx_deliveries_courier_pickup ON deliveries (courier_id, pickup_date);

EXPLAIN ANALYZE
SELECT * FROM deliveries
WHERE courier_id = 1 AND pickup_date BETWEEN '2026-11-25' AND '2026-11-30';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB
-- pr_refresh_deliveries(p_day) - replace row on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_deliveries(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'Day is required'; END IF;
  INSERT INTO daily_deliveries (delivery_day, total_deliveries, total_revenue)
  SELECT p_day,
    COUNT(*) FILTER (WHERE status <> 'cancelled'),
    COALESCE(SUM(total_amount) FILTER (WHERE status <> 'cancelled'), 0)
  FROM deliveries WHERE pickup_date = p_day
  ON CONFLICT (delivery_day) DO UPDATE
  SET total_deliveries = EXCLUDED.total_deliveries,
      total_revenue = EXCLUDED.total_revenue;
END; $$;

CALL pr_refresh_deliveries('2026-11-25');
CALL pr_refresh_deliveries('2026-11-25');

SELECT * FROM daily_deliveries;
SELECT * FROM delivery_audit ORDER BY audit_id;
SELECT fn_courier_total(1, '2026-11-25', '2026-11-30') AS courier1_total;
SELECT fn_courier_total(3, '2026-11-25', '2026-11-30') AS courier3_total;

-- Schedule: Daily at 01:10
-- SELECT cron.schedule('q10_refresh_deliveries', '10 1 * * *', $$CALL pr_refresh_deliveries(CURRENT_DATE - 1);$$);
