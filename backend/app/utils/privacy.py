"""Privacy settings (phone: Settings → Privacy). The checks themselves live in
SQL (veyon_can_see in schema.sql) so every query can apply them in place."""
from app.core.database import one

CHOICES = ("everyone", "contacts", "nobody")


def photo_sql(alias: str, viewer_param: str) -> str:
    """`<alias>.photo_path`, or NULL when the viewer may not see the photo."""
    return f"CASE WHEN veyon_can_see({alias}.id, {viewer_param}::uuid, {alias}.photo_privacy) THEN {alias}.photo_path END"


def last_seen_sql(alias: str, viewer_param: str) -> str:
    return f"CASE WHEN veyon_can_see({alias}.id, {viewer_param}::uuid, {alias}.last_seen_privacy) THEN {alias}.last_seen END"


async def reads_hidden(conversation_id: str) -> bool:
    """Blue ticks are hidden in a 1-to-1 chat when either person turned read
    receipts off (both ways, like WhatsApp). Groups always show them."""
    row = await one(
        """SELECT c.kind, bool_and(u.read_receipts) AS all_on
             FROM conversations c
             JOIN conversation_members cm ON cm.conversation_id = c.id
             JOIN users u ON u.id = cm.user_id
            WHERE c.id = $1
            GROUP BY c.kind""",
        conversation_id,
    )
    return bool(row) and row["kind"] == "direct" and not row["all_on"]
