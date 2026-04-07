"""
tekhton-conductor API — FastAPI control plane.

Provides four endpoints for monitoring and commanding the conductor:
  GET  /status         — full state object
  POST /start-night-run — arm the conductor
  POST /stop           — graceful halt
  GET  /log            — tail the log file
"""

from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from typing import Optional
import os


security = HTTPBearer()


def create_app(conductor) -> FastAPI:
    """Factory that creates the FastAPI app bound to a Conductor instance."""

    app = FastAPI(title="Tekhton Conductor", version="1.0.0")
    expected_token = conductor.config.api_token

    def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
        if credentials.credentials != expected_token:
            raise HTTPException(status_code=401, detail="Invalid bearer token")
        return credentials

    @app.get("/status")
    def get_status(auth=Depends(verify_token)):
        """Return the full conductor state as JSON."""
        return conductor.state.to_dict()

    class StartNightRunRequest(BaseModel):
        starting_milestone: Optional[str] = None

    @app.post("/start-night-run")
    def start_night_run(req: StartNightRunRequest, auth=Depends(verify_token)):
        """Arm the conductor for a night run."""
        try:
            conductor.arm(starting_milestone=req.starting_milestone)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc))
        return {"status": "armed", "starting_milestone": req.starting_milestone}

    @app.post("/stop")
    def stop(auth=Depends(verify_token)):
        """Request graceful stop after current operation completes."""
        conductor.stop()
        return {"status": "stop_requested"}

    @app.get("/log")
    def get_log(lines: int = Query(default=50, ge=1, le=5000),
                auth=Depends(verify_token)):
        """Return the last N lines of the conductor log file."""
        log_path = conductor.config.log_path
        if not os.path.exists(log_path):
            return {"lines": []}
        try:
            with open(log_path, "r") as f:
                all_lines = f.readlines()
            tail = [line.rstrip("\n") for line in all_lines[-lines:]]
            return {"lines": tail}
        except Exception as exc:
            raise HTTPException(status_code=500, detail=f"Failed to read log: {exc}")

    return app
