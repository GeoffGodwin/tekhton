from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def hello() -> dict:
    return {"fixture": "polyglot-services"}
