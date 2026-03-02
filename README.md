# Todo API setup

Launch a PostgreSQL container with a known password and database/user names:

docker run --name todo \
  -e POSTGRES_PASSWORD=todo_123 \
  -e POSTGRES_USER=todo_user \
  -e POSTGRES_DB=todo_db \
  -p 5432:5432 \
  postgres:latest

  # Inside container
psql -U todo_user -d todo_db -h localhost

# After entering password (todo_123)
todo_db=> SELECT * FROM todos;
 id | title | description | completed |          created_at
----+-------+-------------+-----------+-------------------------------
  1 | Buy milk | Testing |      f    | 2026-03-02 10:30:45.123456+00


  -- List all databases
\l

-- Connect to todo_db (if not already connected)
\c todo_db

-- List all tables
\dt

-- View the todos table structure
\d todos

-- Query all records in todos table
SELECT * FROM todos;

-- Count records
SELECT COUNT(*) FROM todos;

-- Exit psql
\q