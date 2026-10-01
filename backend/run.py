"""Start the backend:  python run.py"""
import asyncio

from app.main import run_dual_listener

if __name__ == "__main__":
    asyncio.run(run_dual_listener())
