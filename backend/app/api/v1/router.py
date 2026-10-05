"""Collects every REST router into one, so main.py only mounts this.

Each module keeps its own `/api/...` prefix, the same paths the frontend
already calls.
"""
from fastapi import APIRouter

from app.api.v1 import (
    admin, ai, auth, groups, broadcasts, conversations, gif, labels, link, messages, push, quick_replies,
    reminders, scheduled, status, upload, users, voice,
)

api_router = APIRouter()

for module in (
    auth, users, conversations, upload, status, ai, voice, reminders, push,
    scheduled, messages, labels, link, gif, quick_replies, broadcasts, admin, groups,
):
    api_router.include_router(module.router)
