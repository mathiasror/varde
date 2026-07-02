-- Seeded during `mysqld --initialize-insecure --init-file=/app/init.sql`
-- (see the Dockerfile). DEMO credentials — do not ship real secrets in an
-- image; for production create users at deploy time instead.
CREATE DATABASE demo;
CREATE USER 'demo'@'%' IDENTIFIED BY 'demo-password';
GRANT ALL PRIVILEGES ON demo.* TO 'demo'@'%';
