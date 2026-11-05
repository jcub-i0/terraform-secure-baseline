-- Run as an authorized database owner *after* creating m3_canary_app LOGIN.
-- Use the interactive psql \password m3_canary_app command for its password.
-- No application credential or canary value belongs in this file.
CREATE TABLE IF NOT EXISTS public.m3_canary (
    canary_id varchar(64) PRIMARY KEY,
    payload_sha256 char(64) NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$')
);
REVOKE ALL ON public.m3_canary FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO m3_canary_app;
GRANT SELECT, INSERT ON public.m3_canary TO m3_canary_app;
