import logging
import time
import os

from fastapi import FastAPI, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from sqlalchemy import text
from app import crud
from app import schemas
from app.database import engine, get_db
# import the models module so SQLAlchemy can create tables
from app import models

# configure basic logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("todo_api")

# if running in AWS, add watchtower handler to send logs to CloudWatch
# (watchtower is optional so the import is wrapped; this block may execute
# at import time so we cannot rely on application state yet).
try:
    from typing import TYPE_CHECKING
    if not TYPE_CHECKING:
        import watchtower
        # log group name can be environment configured or default
        log_group = os.getenv("CLOUDWATCH_LOG_GROUP", "todo-api-logs")
        try:
            cw_handler = watchtower.CloudWatchLogHandler(log_group=log_group)
            logger.addHandler(cw_handler)
        except Exception as exc:  # catch boto3/botocore errors such as NoRegionError
            # log a warning but continue – missing AWS credentials/region should
            # not prevent the app from starting.
            logger.warning("CloudWatch handler unavailable: %s", exc)
except ImportError:
    # watchtower not installed or not required in development
    pass

app = FastAPI(title="Todo API", version="0.1.0")

# middleware to log start/end/error of each request
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.time()
    logger.info(f"started request path={request.url.path} method={request.method}")
    try:
        response = await call_next(request)
    except Exception as exc:
        logger.exception(f"error handling request path={request.url.path}")
        raise
    finally:
        elapsed = time.time() - start_time
        status = response.status_code if 'response' in locals() else 'error'
        logger.info(f"completed request path={request.url.path} status={status} duration={elapsed:.3f}s")
    return response


@app.on_event("startup")
def on_startup():
    """Attempt to create tables at startup but don't crash the process if DB is down.

    This prevents the application from failing to start when the database is
    temporarily unavailable (useful during local development or orchestrated
    deployments where the DB may come up later). The health endpoint will still
    report database connectivity issues.
    """
    try:
        models.Base.metadata.create_all(bind=engine)
    except Exception as e:
        # log a warning and continue so the app can serve health checks and
        # allow orchestration to detect the DB problem.
        import logging

        logging.getLogger("uvicorn.error").warning("Could not create tables at startup: %s", e)

@app.get("/.well-known/health")
def health_check():
    """Health check endpoint that verifies database connectivity."""
    try:
        # attempt a simple query to verify database is accessible
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return {"status": "ok", "database": "connected"}
    except Exception as e:
        return {
            "status": "error",
            "database": "disconnected",
            "error": str(e)
        }


from fastapi.responses import RedirectResponse, HTMLResponse
import json
import os


@app.get("/.well-known/swagger.json")
def swagger_document_json():
    """Return the OpenAPI (Swagger) JSON document for the service.

    This keeps the machine-readable spec available at a stable URL.
    """
    return app.openapi()


@app.get("/.well-known/swagger")
def swagger_document_html():
    """Serve a human-readable Swagger UI for the service.

    This reads the static swagger.json file from disk and displays it in an
    embedded Swagger UI. Falls back to app.openapi() if the file is missing.
    """
    # Load the static swagger.json from the project root
    swagger_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "swagger.json")
    try:
        with open(swagger_path, "r") as f:
            spec = json.load(f)
        spec_json = json.dumps(spec)
    except FileNotFoundError:
        # If the file doesn't exist, fall back to app.openapi()
        spec_json = json.dumps(app.openapi())

    html = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>API Swagger UI</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@4/swagger-ui.css" />
    <style>
      html, body {{ margin:0; padding:0; height:100%; }}
      #swagger-ui {{ height: 100vh; }}
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@4/swagger-ui-bundle.js"></script>
    <script>
      window.addEventListener('load', function() {{
        const ui = SwaggerUIBundle({{
          spec: {spec_json},
          dom_id: '#swagger-ui',
          presets: [SwaggerUIBundle.presets.apis],
          layout: 'BaseLayout'
        }});
        window.ui = ui;
      }});
    </script>
  </body>
</html>"""
    return HTMLResponse(content=html, status_code=200)

@app.post("/todos", response_model=schemas.TodoResponse)
def create(todo: schemas.TodoCreate, db: Session = Depends(get_db)):
    return crud.create_todo(db, todo)

@app.get("/todos", response_model=list[schemas.TodoResponse])
def read_all(db: Session = Depends(get_db)):
    return crud.get_todos(db)

@app.get("/todos/{todo_id}", response_model=schemas.TodoResponse)
def read_one(todo_id: int, db: Session = Depends(get_db)):
    db_todo = crud.get_todo(db, todo_id)
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    return db_todo

@app.put("/todos/{todo_id}", response_model=schemas.TodoResponse)
def update(todo_id: int, todo: schemas.TodoUpdate, db: Session = Depends(get_db)):
    db_todo = crud.update_todo(db, todo_id, todo)
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    return db_todo

@app.delete("/todos/{todo_id}")
def delete(todo_id: int, db: Session = Depends(get_db)):
    db_todo = crud.delete_todo(db, todo_id)
    if not db_todo:
        raise HTTPException(status_code=404, detail="Todo not found")
    return {"message": "Deleted successfully"}