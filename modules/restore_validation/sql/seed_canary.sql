-- Execute as a privileged operator *only* on the SOURCE PostgreSQL instance.
-- This fixture is synthetic, idempotent, and contains no application data.
BEGIN;
CREATE SCHEMA IF NOT EXISTS restore_validation;
REVOKE ALL ON SCHEMA restore_validation FROM PUBLIC;
CREATE TABLE IF NOT EXISTS restore_validation.canary (
  marker_id TEXT PRIMARY KEY,
  marker_value TEXT NOT NULL
);
REVOKE ALL ON TABLE restore_validation.canary FROM PUBLIC;
INSERT INTO restore_validation.canary (marker_id, marker_value) VALUES
  ('alpha', 'terraform-secure-baseline:restore-validation:v1'),
  ('bravo', 'aws-backup:rds:synthetic-integrity-marker'),
  ('charlie', 'no-production-data-or-pii')
ON CONFLICT (marker_id) DO UPDATE SET marker_value = EXCLUDED.marker_value;
COMMIT;
-- Create a dedicated LOGIN role using a generated password kept in Secrets Manager.
-- Grant only CONNECT on the database, USAGE on the schema, and SELECT on this table:
-- GRANT CONNECT ON DATABASE your_database TO restore_validation_reader;
-- GRANT USAGE ON SCHEMA restore_validation TO restore_validation_reader;
-- GRANT SELECT ON restore_validation.canary TO restore_validation_reader;
