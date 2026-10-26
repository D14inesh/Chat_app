"""Collects every REST router into one, so main.py only mounts this.

Each module keeps its own `/api/...` prefix, the same paths the frontend
already calls.
"""
from fastapi import APIRouter

from app.api.v1 import (
    ai, auth, backup, branding, business_tools, calls, chat_extras, groups, broadcasts, conversations, gif, labels, link, messages, push, quick_replies,
    reminders, scheduled, signal, status, upload, users, voice,
)

api_router = APIRouter()

for module in (
    auth, users, conversations, upload, status, ai, voice, reminders, push,
    scheduled, messages, labels, link, gif, quick_replies, broadcasts, groups, chat_extras, calls, business_tools, signal, backup, branding,
):
    api_router.include_router(module.router)
