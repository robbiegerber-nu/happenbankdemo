-- Run against the default "postgres" database.
-- WARNING: drops and recreates happen_demo (safe to re-run; it only touches happen_demo).
\set ON_ERROR_STOP on
DROP DATABASE IF EXISTS happen_demo;
CREATE DATABASE happen_demo;
ALTER DATABASE happen_demo SET timezone = 'America/Chicago';
