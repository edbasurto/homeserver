-- Runs once on first postgres startup (data dir must be empty).
-- Creates one database per devs-talk service that shares this postgres instance.
-- The POSTGRES_USER (devs) is already a superuser — no GRANT needed.

CREATE DATABASE forgejo;
CREATE DATABASE semaphore;
CREATE DATABASE planka;
CREATE DATABASE wikijs;
