import os
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from sqlalchemy.orm import sessionmaker

# We'll override the DB dependency to use an in-memory DB below
# Provide a harmless DATABASE_URL so app.config import doesn't raise.
import os as _os
_os.environ.setdefault("DATABASE_URL", "sqlite:///./todo_test_temp.db")
from app.main import app
from app.database import get_db
from app.models import Base as ModelsBase

# Use an in-memory SQLite database for tests (no file on disk)
TEST_DATABASE_URL = "sqlite:///:memory:"
# Use StaticPool so the in-memory SQLite database is persisted across connections
engine = create_engine(
    TEST_DATABASE_URL,
    connect_args={"check_same_thread": False},
    poolclass=StaticPool,
)
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Create tables on the test engine
ModelsBase.metadata.create_all(bind=engine)

def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()

app.dependency_overrides[get_db] = override_get_db

client = TestClient(app)

def test_create_todo():
    response = client.post("/todos", json={
        "title": "Test Todo",
        "description": "Testing"
    })
    assert response.status_code == 200
    assert response.json()["title"] == "Test Todo"

def test_get_todos():
    response = client.get("/todos")
    assert response.status_code == 200