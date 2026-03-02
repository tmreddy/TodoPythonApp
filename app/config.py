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
