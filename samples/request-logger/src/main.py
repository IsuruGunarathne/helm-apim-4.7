import json
import logging
from typing import Optional

import yaml
from fastapi import FastAPI, HTTPException, Request, Response
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("request_logger")

app = FastAPI(title="Book Request Logger", version="1.0.0")

books_db: dict = {}
next_id: int = 1


class BookPayload(BaseModel):
    title: Optional[str] = None
    author: Optional[str] = None
    year: Optional[int] = None


async def log_request(request: Request):
    headers = "\n".join(
        f"    {k}: {v}" for k, v in request.headers.items()
    )
    lines = [
        "─" * 60,
        f"  {request.method} {request.url.path}",
        "  Headers:",
        headers,
    ]
    raw = await request.body()
    if raw:
        try:
            parsed = json.loads(raw)
            formatted = json.dumps(parsed, indent=4, ensure_ascii=False)
        except json.JSONDecodeError:
            formatted = raw.decode(errors="replace")
        lines += ["  Body:", *[f"    {line}" for line in formatted.splitlines()]]
    lines.append("─" * 60)
    logger.info("\n" + "\n".join(lines))


@app.get("/openapi.yaml", include_in_schema=False)
async def openapi_yaml():
    content = yaml.dump(app.openapi(), allow_unicode=True, sort_keys=False)
    return Response(content=content, media_type="application/yaml")


@app.get("/books")
async def list_books(request: Request):
    await log_request(request)
    return books_db


@app.post("/books", status_code=201)
async def create_book(payload: BookPayload, request: Request):
    global next_id
    await log_request(request)
    book_id = next_id
    books_db[book_id] = payload.model_dump()
    next_id += 1
    return {"id": book_id, "book": books_db[book_id]}


@app.put("/books/{book_id}")
async def update_book(book_id: int, payload: BookPayload, request: Request):
    await log_request(request)
    if book_id not in books_db:
        raise HTTPException(status_code=404, detail=f"Book {book_id} not found")
    books_db[book_id].update({k: v for k, v in payload.model_dump().items() if v is not None})
    return {"id": book_id, "book": books_db[book_id]}


@app.delete("/books/{book_id}", status_code=204)
async def delete_book(book_id: int, request: Request):
    await log_request(request)
    if book_id not in books_db:
        raise HTTPException(status_code=404, detail=f"Book {book_id} not found")
    books_db.pop(book_id)
