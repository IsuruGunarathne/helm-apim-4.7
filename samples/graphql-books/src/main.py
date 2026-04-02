from __future__ import annotations

import logging
from typing import Optional

import strawberry
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from strawberry.fastapi import GraphQLRouter

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("graphql_books")

books_db: dict = {}
next_id: int = 1


# ── GraphQL types ─────────────────────────────────────────────────────────────

@strawberry.type
class Book:
    id: int
    title: str
    author: str
    year: Optional[int] = None


# ── Queries ───────────────────────────────────────────────────────────────────

@strawberry.type
class Query:
    @strawberry.field
    def books(self) -> list[Book]:
        logger.info("Query: books() → %d result(s)", len(books_db))
        return [Book(**b) for b in books_db.values()]

    @strawberry.field
    def book(self, id: int) -> Optional[Book]:
        logger.info("Query: book(id=%d)", id)
        data = books_db.get(id)
        return Book(**data) if data else None


# ── Mutations ─────────────────────────────────────────────────────────────────

@strawberry.type
class Mutation:
    @strawberry.mutation
    def create_book(self, title: str, author: str, year: Optional[int] = None) -> Book:
        global next_id
        data = {"id": next_id, "title": title, "author": author, "year": year}
        books_db[next_id] = data
        logger.info("Mutation: createBook → id=%d, title=%s", next_id, title)
        next_id += 1
        return Book(**data)

    @strawberry.mutation
    def update_book(
        self,
        id: int,
        title: Optional[str] = None,
        author: Optional[str] = None,
        year: Optional[int] = None,
    ) -> Optional[Book]:
        """Partial update — omit or pass null for any field you don't want to change."""
        if id not in books_db:
            logger.info("Mutation: updateBook(id=%d) → not found", id)
            return None
        data = books_db[id]
        if title is not None:
            data["title"] = title
        if author is not None:
            data["author"] = author
        if year is not None:
            data["year"] = year
        logger.info("Mutation: updateBook(id=%d) → %s", id, data)
        return Book(**data)

    @strawberry.mutation
    def delete_book(self, id: int) -> bool:
        if id not in books_db:
            logger.info("Mutation: deleteBook(id=%d) → not found", id)
            return False
        del books_db[id]
        logger.info("Mutation: deleteBook(id=%d) → deleted", id)
        return True


# ── App setup ─────────────────────────────────────────────────────────────────

schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_router = GraphQLRouter(schema)

app = FastAPI(title="GraphQL Books API", version="1.0.0")
app.include_router(graphql_router, prefix="/graphql")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/schema", response_class=PlainTextResponse)
async def get_schema():
    """Returns the GraphQL SDL schema — use this to register the API in WSO2 APIM Publisher."""
    return schema.as_str()
