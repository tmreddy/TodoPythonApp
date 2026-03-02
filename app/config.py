import os
from dotenv import load_dotenv

load_dotenv()

# Require DATABASE_URL to be set explicitly. Do not fall back to SQLite.
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError(
        "DATABASE_URL environment variable is required.\n"
        "Set it in the environment or in a .env file before starting the app."
    )

# make sure the string is a valid SQLAlchemy URL, since an empty string or
# malformed value will otherwise produce a confusing `ArgumentError` later
# during engine creation.  We import lazily here so SQLAlchemy isn’t required
# just to load configuration.
try:
    from sqlalchemy.engine.url import make_url
    # this will raise if the URL cannot be parsed
    make_url(DATABASE_URL)
except Exception as exc:  # pragma: no cover - very hard to trigger in tests
    raise RuntimeError(
        f"DATABASE_URL is not a valid SQLAlchemy URL: {DATABASE_URL!r}: {exc}"
    )
