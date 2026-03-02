from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict


# enable reading from ORM objects
model_config = ConfigDict(from_attributes=True)


class TodoBase(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    title: str
    description: Optional[str] = None
    completed: Optional[bool] = False


class TodoCreate(TodoBase):
    pass


class TodoUpdate(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None


class TodoResponse(TodoBase):
    id: int
    created_at: datetime

    # inherit from_attributes via TodoBase
