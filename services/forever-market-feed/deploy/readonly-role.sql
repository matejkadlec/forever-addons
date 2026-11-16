-- The read-only role of the API. `forever-market-feed-deploy init` runs this once as the database owner (feed)
-- and then sets the role's password from /etc/forever-market-feed/api-database.env; nobody types it.
CREATE ROLE feed_api LOGIN;
GRANT CONNECT ON DATABASE feed TO feed_api;
GRANT USAGE ON SCHEMA public TO feed_api;
-- the collector (feed, owner of the tables) creates them later: SELECT on everything it creates
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO feed_api;
