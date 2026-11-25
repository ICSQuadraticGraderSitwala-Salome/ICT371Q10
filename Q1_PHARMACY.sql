-- ============================================================
-- ICT371 - QUESTION 2: University Fee Payments
-- ============================================================

-- ------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6 marks]
-- Create 4 tables with keys and constraints
-- Credit balances are NOT allowed
-- ------------------------------------------------------------
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(12,2) NOT NULL,
  logged_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed: 3 students with different fee balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
('STU001', 'Alice Banda', 5000.00),
('STU002', 'Brian Mwanza', 3000.00),
('STU003', 'Carol Phiri', 4000.00);

-- ------------------------------------------------------------
-- (b) FUNCTION 
-- fn_fee_balance(p_student_id) = fee_due - total payments
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student: %', p_student_id; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN ROUND(v_fee - v_paid, 2);
END; $$;

-- ------------------------------------------------------------
-- (c) PROCEDURE
-- pr_receive_payment(p_student_id, p_amount, p_paid_on)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
  IF p_student_id IS NULL THEN RAISE EXCEPTION 'Student ID is required'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF p_paid_on IS NULL THEN RAISE EXCEPTION 'paid_on is required'; END IF;
  -- This also rejects unknown student
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment %.2f exceeds outstanding balance %.2f', p_amount, v_balance;
  END IF;
  -- Insert only. Do NOT change fee_due.
  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END; $$;

-- ------------------------------------------------------------
-- (d) TRIGGER 
-- AFTER INSERT on payments -> payment_audit
-- Procedure must NOT insert audit itself
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payment_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_payment_audit ON payments;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit_fn();

-- ------------------------------------------------------------
-- (a) CONTINUED: Seed at least 6 payments THROUGH procedure
-- STU003 Carol has NO payments initially (as required)
-- ------------------------------------------------------------
CALL pr_receive_payment(1, 1000.00, '2026-11-20');
CALL pr_receive_payment(1, 1500.00, '2026-11-20');
CALL pr_receive_payment(1, 500.00, '2026-11-21');
CALL pr_receive_payment(2, 1000.00, '2026-11-20');
CALL pr_receive_payment(2, 500.00, '2026-11-21');
CALL pr_receive_payment(2, 500.00, '2026-11-21');

-- ------------------------------------------------------------
-- (e) VIEW 
-- v_fee_balances - only students who still owe fees
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
  ROUND(s.fee_due - COALESCE(SUM(p.amount), 0), 2) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0)) > 0;

-- Query the view:
SELECT * FROM v_fee_balances;

-- ------------------------------------------------------------
-- (f) INDEX 
-- For payments filtered by student_id and paid_on date range
-- ------------------------------------------------------------
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

-- Justification: Composite (student_id, paid_on) lets Postgres seek
-- directly to that student, then range-scan only those dates,
-- instead of scanning all payments.

-- Matching query and EXPLAIN:
EXPLAIN ANALYZE
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN '2026-11-20' AND '2026-11-21';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB
-- pr_refresh_collections(p_day) - replace row on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
  SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END; $$;

-- Test: run twice, must NOT double-count
CALL pr_refresh_collections('2026-11-20');
CALL pr_refresh_collections('2026-11-20');
CALL pr_refresh_collections('2026-11-21');

-- Verify:
SELECT * FROM daily_collections ORDER BY collection_date;
SELECT * FROM payment_audit ORDER BY audit_id;
SELECT fn_fee_balance(1) AS alice_balance;
SELECT fn_fee_balance(3) AS carol_balance;

-- Schedule: Daily at 01:00 for the previous day
-- SELECT cron.schedule('q2_refresh_collections', '0 1 * * *', $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$);
-- Inspect job: SELECT * FROM cron.job;