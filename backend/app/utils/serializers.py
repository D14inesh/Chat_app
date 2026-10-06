"""Row -> API DTO shaping helpers shared between REST routes, the WebSocket
hub, and the schedulers. This must stay ONE implementation used everywhere a
message/conversation gets serialized — the Node app deliberately reuses
conversations.js's shapeMessage from ws/hub.js for exactly this reason: a
message broadcast live over the socket must be byte-identical in shape to one
fetched via REST history."""


def shape_conversation(r: dict) -> dict:
    base = {
        "id": r["id"],
        "kind": r["kind"],
        "unread": int(r.get("unread") or 0),
        "favorite": bool(r.get("favorite")),
        "wallpaper": r.get("wallpaper"),
        "wallpaperPhotoUrl": (
            f"/api/conversations/{r['id']}/wallpaper-photo"
            if r.get("wallpaper") == "photo" and r.get("wallpaper_photo_path")
            else None
        ),
        "wallpaperFit": r.get("wallpaper_fit") or "cover",
        "muted": bool(r.get("muted")),
        # Hidden behind my chat-lock PIN (per person, like muted).
        "locked": bool(r.get("locked")),
        "archived": bool(r.get("archived")),
        "disappearSeconds": int(r.get("disappear_seconds") or 0),
        "pinnedMessage": r.get("pinned_message"),
        "pinnedBy": r.get("pinned_by"),
        "lastMessage": (
            {
                "id": r["last_id"],
                "senderId": r["last_sender"],
                "kind": r["last_kind"],
                "ciphertext": r["last_ciphertext"],
                "iv": r["last_iv"],
                "createdAt": r["last_at"],
                "deliveredAt": r["last_delivered"],
                "readAt": r["last_read"],
                "viewOnce": bool(r.get("last_view_once")),
            }
            if r.get("last_id")
            else None
        ),
    }

    if r["kind"] == "group":
        return {
            **base,
            "title": r.get("title"),
            "avatarColor": r.get("group_avatar_color"),
            "memberCount": int(r.get("member_count") or 0),
            "description": r.get("description") or "",
            "onlyAdminsSend": bool(r.get("only_admins_send")),
            "myRole": r.get("my_role") or "member",
            # Admins only: the invite link code and waiting join requests.
            "inviteCode": r.get("invite_code") if r.get("my_role") in ("owner", "admin") else None,
            "joinRequests": int(r.get("join_requests") or 0) if r.get("my_role") in ("owner", "admin") else 0,
            "communityId": r.get("community_id"),
            "isAnnouncement": bool(r.get("is_announcement")),
        }

    return {
        **base,
        "status": r.get("status") or "accepted",
        "requestedBy": r.get("requested_by"),
        "peer": {
            "id": r.get("peer_id"),
            "username": r.get("peer_username"),
            "displayName": r.get("peer_name"),
            "avatarColor": r.get("peer_color"),
            "about": r.get("peer_about"),
            "photoUrl": f"/api/users/{r['peer_id']}/photo" if r.get("peer_photo_path") else None,
            "lastSeen": r.get("peer_last_seen"),
            "publicKey": r.get("peer_public_key"),
        },
    }


def shape_message(r: dict, reactions: list | None = None, votes: list | None = None,
                  opened_by: list | None = None) -> dict:
    return {
        "id": r["id"],
        "senderId": r["sender_id"],
        "kind": r["kind"],
        "ciphertext": r["ciphertext"],
        "iv": r["iv"],
        "filePath": r.get("file_path"),
        "fileSize": int(r["file_size"]) if r.get("file_size") else None,
        "createdAt": r["created_at"],
        "deliveredAt": r.get("delivered_at"),
        "readAt": r.get("read_at"),
        "editedAt": r.get("edited_at"),
        "replyToId": r.get("reply_to_id"),
        "reactions": reactions or [],
        # Polls: [{userId, choices: [optionIndex, ...]}]
        "votes": votes or [],
        # View-once media: who has already opened it.
        "viewOnce": bool(r.get("view_once")),
        "openedBy": opened_by or [],
        # Disappearing messages: when it vanishes (null = never).
        "expiresAt": r.get("expires_at"),
        # Polls with a deadline (or closed by their creator).
        "pollClosesAt": r.get("poll_closes_at"),
        # "@everyone" in a group.
        "mentionAll": bool(r.get("mention_all")),
    }


DEFAULT_APPEARANCE = {"palette": "veyon", "mode": "dark", "structure": "floating"}


def shape_user(r: dict) -> dict:
    """Mirrors auth.js's local shape() — merges appearance over the default
    and derives photoUrl from photo_path."""
    appearance = {**DEFAULT_APPEARANCE, **(r.get("appearance") or {})}
    return {
        "id": r["id"],
        "username": r["username"],
        "displayName": r["display_name"],
        "avatarColor": r["avatar_color"],
        "about": r["about"],
        "photoUrl": f"/api/users/{r['id']}/photo" if r.get("photo_path") else None,
        "publicKey": r.get("public_key"),
        "lastSeen": r.get("last_seen"),
        "appearance": appearance,
        "business": shape_business(r.get("business")),
    }


BUSINESS_FIELDS = ("category", "description", "address", "hours", "email", "website")


def shape_business(b: dict | None) -> dict | None:
    """Only an enabled business profile is shown to anyone."""
    if not b or not b.get("enabled"):
        return None
    return {"enabled": True, **{k: b.get(k) or "" for k in BUSINESS_FIELDS}}
