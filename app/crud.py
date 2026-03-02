from sqlalchemy.orm import Session
from app.models import Todo
from app import schemas

def create_todo(db: Session, todo: schemas.TodoCreate):
    # use model_dump() for Pydantic v2 instead of deprecated dict()
    db_todo = Todo(**todo.model_dump())
    db.add(db_todo)
    db.commit()
    db.refresh(db_todo)
    return db_todo

def get_todos(db: Session):
    return db.query(Todo).all()

def get_todo(db: Session, todo_id: int):
    return db.query(Todo).filter(Todo.id == todo_id).first()

def update_todo(db: Session, todo_id: int, todo: schemas.TodoUpdate):
    db_todo = get_todo(db, todo_id)
    if not db_todo:
        return None

    for key, value in todo.dict(exclude_unset=True).items():
        setattr(db_todo, key, value)

    db.commit()
    db.refresh(db_todo)
    return db_todo

def delete_todo(db: Session, todo_id: int):
    db_todo = get_todo(db, todo_id)
    if not db_todo:
        return None
    db.delete(db_todo)
    db.commit()
    return db_todo