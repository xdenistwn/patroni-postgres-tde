/* Create table with pg_tde extension */
CREATE TABLE secure_data (
  id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT,
  amount NUMERIC(10,2),
  created_at DATE
) USING tde_heap;

INSERT INTO secure_data (name, amount, created_at) VALUES
('Alice', 1234.56, '2025-08-01'),
('Bob', 7890.12, '2025-08-10'),
('Charlie', 345.67, '2025-08-19');

select * from secure_data;

/* Create table without pg_tde extension */
CREATE TABLE plain_data (
  id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name TEXT,
  amount NUMERIC(10,2),
  created_at DATE
);

INSERT INTO plain_data (name, amount, created_at) VALUES
('Alice', 1234.56, '2025-08-01'),
('Bob', 7890.12, '2025-08-10'),
('Charlie', 345.67, '2025-08-19');

select * from plain_data;

/* query tde server info */
/* detail: https://docs.percona.com/pg-tde/functions.html#pg_tde_is_encrypted */
SELECT pg_tde_key_info();

/* query tde table info */
/* detail: https://docs.percona.com/pg-tde/functions.html#pg_tde_is_encrypted */
SELECT pg_tde_is_encrypted('secure_data');
