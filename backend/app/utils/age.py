"""Age rules: 1-to-1 chats and calls are for people 18 and over.
Under-18s (13+) can use the app for groups. Ages come from the date of
birth each person gives — the server can't verify it."""
from datetime import date

from fastapi import HTTPException

from app.core.database import one

ADULT = 18
MIN_AGE = 13

ADULT_ONLY_MSG = "1-to-1 chats are for people 18 and over. You can still use groups."
PEER_MINOR_MSG = "This person can't receive 1-to-1 chats."
NEED_BIRTH_MSG = "Add your date of birth first (it's asked when you open the app)."


def age_on(birth: date, today: date | None = None) -> int:
    today = today or date.today()
    return today.year - birth.year - ((today.month, today.day) < (birth.month, birth.day))


def parse_birth_date(raw) -> date:
    try:
        d = date.fromisoformat(str(raw or "").strip()[:10])
    except ValueError:
        raise HTTPException(400, "Enter your date of birth.")
    years = age_on(d)
    if d > date.today() or years > 120:
        raise HTTPException(400, "That date of birth doesn't look right.")
    if years < MIN_AGE:
        raise HTTPException(400, f"You need to be at least {MIN_AGE} to use Veyon Chat.")
    return d


def is_adult(birth: date | None) -> bool:
    return birth is not None and age_on(birth) >= ADULT


async def adult(user_id: str) -> bool:
    row = await one("SELECT birth_date FROM users WHERE id = $1", user_id)
    return bool(row) and is_adult(row["birth_date"])


async def require_direct_allowed(me: str, peer: str) -> None:
    """Both people must be 18+ for a 1-to-1 chat or call."""
    row = await one("SELECT birth_date FROM users WHERE id = $1", me)
    if not row or row["birth_date"] is None:
        raise HTTPException(403, NEED_BIRTH_MSG)
    if not is_adult(row["birth_date"]):
        raise HTTPException(403, ADULT_ONLY_MSG)
    if not await adult(peer):
        raise HTTPException(403, PEER_MINOR_MSG)
