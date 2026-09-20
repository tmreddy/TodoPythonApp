# Todo API

A FastAPI CRUD service for todos, backed by PostgreSQL.

The steps below are for running the app locally. For everything else:

| Guide | For |
|---|---|
| [devops.md](devops.md) | **Start here** if containers, Kubernetes or CI/CD are new — the whole cycle from zero |
| [pipeline-flow.md](pipeline-flow.md) | Step-by-step trace of what runs when you push, and where it fails |
| [terraform/README.md](terraform/README.md) | Provisioning and tearing down the AWS infrastructure |
| [k8s/README.md](k8s/README.md) | The Kubernetes manifests, probes and rollouts |
| [cloudwatch.md](cloudwatch.md) | Reading and searching the logs |
| [deployment.md](deployment.md) | The older manual route: a single EC2 instance + RDS |

The quickest way to run the containerized stack locally is Docker Compose, which
starts the app and PostgreSQL together:

```bash
docker compose up --build
curl http://localhost:8000/.well-known/ready
```

## Prerequisites

- Python 3.9 or newer
- Docker (to run PostgreSQL locally)

## 1. Start PostgreSQL

Launch a PostgreSQL container with a known password and database/user names:

```bash
docker run -d --name todo \
  -e POSTGRES_PASSWORD=todo_123 \
  -e POSTGRES_USER=todo_user \
  -e POSTGRES_DB=todo_db \
  -p 5432:5432 \
  postgres:latest
```

If the container already exists from a previous run, start it again with
`docker start todo`.

## 2. Install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 3. Configure DATABASE_URL

`DATABASE_URL` is required — the app refuses to start without it and does not
fall back to SQLite. Export it in your shell:

```bash
export DATABASE_URL='postgresql://todo_user:todo_123@localhost:5432/todo_db'
```

A `.env` file in the project root works too, since the app calls `load_dotenv()`
on startup:

```bash
DATABASE_URL=postgresql://todo_user:todo_123@localhost:5432/todo_db
```

`.env` is covered by `.gitignore`, so it won't be committed. Be aware of one
wrinkle if you go that route, though: it makes
`test_config.py::test_missing_database_url` fail (see
[Running the tests](#running-the-tests)).

## 4. Run the application

```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Drop `--reload` if you don't want the server to restart on file changes. The
app creates the `todos` table at startup if it doesn't already exist.

## 5. Verify it's working

```bash
curl http://127.0.0.1:8000/.well-known/health
# {"status":"ok","database":"connected"}
```

If `database` reports `disconnected`, the app is up but cannot reach
PostgreSQL — check that the container is running and `DATABASE_URL` is correct.

Interactive API docs:

- Swagger UI: http://127.0.0.1:8000/.well-known/swagger
- OpenAPI JSON: http://127.0.0.1:8000/.well-known/swagger.json
- FastAPI's built-in docs: http://127.0.0.1:8000/docs

## Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/todos` | Create a todo |
| `GET` | `/todos` | List all todos |
| `GET` | `/todos/{id}` | Get one todo (404 if missing) |
| `PUT` | `/todos/{id}` | Update a todo (404 if missing) |
| `DELETE` | `/todos/{id}` | Delete a todo (404 if missing) |
| `GET` | `/.well-known/health` | Liveness: always 200, reports DB state in the body |
| `GET` | `/.well-known/ready` | Readiness: 200 when the DB is reachable, 503 when not |

Example requests:

```bash
# Create
curl -X POST http://127.0.0.1:8000/todos \
  -H 'Content-Type: application/json' \
  -d '{"title":"Buy milk","description":"2% organic"}'

# List
curl http://127.0.0.1:8000/todos

# Mark complete
curl -X PUT http://127.0.0.1:8000/todos/1 \
  -H 'Content-Type: application/json' \
  -d '{"title":"Buy milk","description":"2% organic","completed":true}'

# Delete
curl -X DELETE http://127.0.0.1:8000/todos/1
```

## Postman collection

A ready-to-run collection lives in [postman/](postman/):

| File | Purpose |
|---|---|
| `TodoAPI.postman_collection.json` | All endpoints, with assertions |
| `TodoAPI.postman_environment.json` | Sets `baseUrl` to `http://127.0.0.1:8000` |

Import both into Postman (**Import** → drag the two files in), select the
**Todo API - Local** environment, then start the app and send requests.

The `Todos` folder is ordered as a lifecycle and is safe to run with the
Collection Runner: **Create todo** saves the new id into the `todoId` collection
variable, and **Get / Update / Delete** reuse it, so the run cleans up after
itself. It also covers the 404 path for a missing id. The **Service** folder
holds the health check and the API-docs endpoints.

`baseUrl` is defined both in the collection and in the environment file — point
it at a deployed host to run the same requests against a remote instance.

## Running the tests

The test suite uses an in-memory SQLite database, so no PostgreSQL container or
`DATABASE_URL` is needed:

```bash
pytest
```

All 12 tests pass on a clean checkout. One caveat: if you created a `.env` file
in step 3, `test_config.py::test_missing_database_url` will fail with
`DID NOT RAISE`. That test unsets `DATABASE_URL` and expects `app.config` to
raise, but reloading the module calls `load_dotenv()`, which reads the value
straight back off disk. Either run tests without a `.env` present, or export
`DATABASE_URL` in your shell instead of using a file.

## Optional: CloudWatch logging

The app logs to stdout by default. If `AWS_REGION` (or `AWS_DEFAULT_REGION`) is
set, it also tries to attach a CloudWatch handler, writing to the log group
named by `CLOUDWATCH_LOG_GROUP` (default `todo-api-logs`). When that handler
can't be created, the app logs a warning and keeps running with stdout logging
only — it is never fatal.

New to CloudWatch? [cloudwatch.md](cloudwatch.md) explains it from scratch: the
vocabulary, how this app ships logs, how to read and search them, and why the
group looks empty for the first minute.

## Inspecting the database

```bash
# Open a psql shell inside the container
docker exec -it todo psql -U todo_user -d todo_db
```

This needs no local PostgreSQL client. If you do have `psql` installed on your
host, you can connect directly instead (password is `todo_123`):

```bash
psql -U todo_user -d todo_db -h localhost
```

Useful psql commands:

```sql
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
```

Example output of `SELECT * FROM todos;`:

```
 id |  title   | description | completed |          created_at
----+----------+-------------+-----------+-------------------------------
  1 | Buy milk | 2% organic  | t         | 2026-09-18 06:49:32.956613+00
```

## Troubleshooting

**`RuntimeError: DATABASE_URL environment variable is required`** — the variable
isn't set in your shell or `.env`. See step 3.

**`DATABASE_URL does not appear to include a scheme`** — you supplied only a
hostname. Use the full connection string, starting with `postgresql://`.

**`connection refused` on port 5432** — the PostgreSQL container isn't running.
Check with `docker ps` and start it with `docker start todo`.
