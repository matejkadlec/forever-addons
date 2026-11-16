-- Runs once when the database is created (docker-entrypoint-initdb.d): a read-only role for the API.
-- Set its password afterwards (the owner, never in git):  ALTER ROLE feed_api PASSWORD '...';
CREATE ROLE feed_api LOGIN;
GRANT CONNECT ON DATABASE feed TO feed_api;
GRANT USAGE ON SCHEMA public TO feed_api;
-- the collector (POSTGRES_USER, owner of the tables) creates them later: SELECT on everything it creates
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO feed_api;
