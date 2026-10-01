"""Mirrors src/routes/status.js."""
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import are_accepted_contacts, one, query, transaction

router = APIRouter(prefix="/api/status", dependencies=[Depends(require_auth)])


def shape_status(r: dict) -> dict:
    return {
        "id": r["id"],
        "kind": r["kind"],
        "ciphertext": r["ciphertext"],
        "iv": r["iv"],
        "filePath": r.get("file_path"),
        "fileSize": int(r["file_size"]) if r.get("file_size") else None,
        "audioCiphertext": r.get("audio_ciphertext"),
        "audioIv": r.get("audio_iv"),
        "audioFilePath": r.get("audio_file_path"),
        "audioFileSize": int(r["audio_file_size"]) if r.get("audio_file_size") else None,
        "audience": r.get("audience") or "contacts",
        "createdAt": r["created_at"],
        "expiresAt": r["expires_at"],
        "viewed": bool(r.get("viewed")),
    }


@router.post("", status_code=201)
async def post_status(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    kind = body.get("kind")
    ciphertext = body.get("ciphertext")
    iv = body.get("iv")
    file_path = body.get("filePath")
    file_size = body.get("fileSize")
    keys = body.get("keys")
    audio_ciphertext = body.get("audioCiphertext")
    audio_iv = body.get("audioIv")
    audio_file_path = body.get("audioFilePath")
    audio_file_size = body.get("audioFileSize")
    audience = body.get("audience")
    mentions = body.get("mentions")

    if kind not in ("text", "image", "video"):
        raise HTTPException(400, "Bad status kind.")
    if not ciphertext or not iv:
        raise HTTPException(400, "Missing status content.")
    if kind in ("image", "video") and not file_path:
        raise HTTPException(400, "This status is missing its file.")
    if not isinstance(keys, list) or len(keys) == 0:
        raise HTTPException(400, "No recipients to share this with.")

    audience_value = "selected" if audience == "selected" else "contacts"
    has_audio = bool(audio_ciphertext or audio_iv or audio_file_path)
    if has_audio and not (audio_ciphertext and audio_iv and audio_file_path):
        raise HTTPException(400, "Incomplete audio attachment.")

    if not any(k.get("viewerId") == user_id for k in keys):
        raise HTTPException(400, "Missing a key for yourself — cannot post.")

    other_viewer_ids = list({k["viewerId"] for k in keys if k.get("viewerId") and k["viewerId"] != user_id})
    if not await are_accepted_contacts(user_id, other_viewer_ids):
        raise HTTPException(400, "You can only share a status with accepted contacts.")

    mention_ids = list({i for i in (mentions or []) if i and i != user_id}) if isinstance(mentions, list) else []
    keyed_viewer_ids = {k["viewerId"] for k in keys}
    if any(i not in keyed_viewer_ids for i in mention_ids):
        raise HTTPException(400, "Can only mention someone who can see this status.")

    async with transaction() as conn:
        row = await conn.fetchrow(
            """INSERT INTO statuses (user_id, kind, ciphertext, iv, file_path, file_size,
                                     audio_ciphertext, audio_iv, audio_file_path, audio_file_size, audience)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
               RETURNING id, user_id, kind, ciphertext, iv, file_path, file_size,
                         audio_ciphertext, audio_iv, audio_file_path, audio_file_size,
                         audience, created_at, expires_at""",
            user_id, kind, ciphertext, iv, file_path, file_size,
            audio_ciphertext, audio_iv, audio_file_path, audio_file_size, audience_value,
        )
        status_row = dict(row)

        for k in keys:
            if not k.get("viewerId") or not k.get("wrappedKey") or not k.get("wrappedIv"):
                continue
            await conn.execute(
                "INSERT INTO status_keys (status_id, viewer_id, wrapped_key, wrapped_iv) VALUES ($1, $2, $3, $4)",
                status_row["id"], k["viewerId"], k["wrappedKey"], k["wrappedIv"],
            )
        for viewer_id in mention_ids:
            await conn.execute(
                "INSERT INTO status_mentions (status_id, mentioned_user_id) VALUES ($1, $2)",
                status_row["id"], viewer_id,
            )

    return {"status": shape_status({**status_row, "viewed": False, "mentions": mention_ids})}


@router.get("")
async def list_statuses(user_id: str = Depends(require_auth)):
    rows = await query(
        """WITH contacts AS (
             SELECT DISTINCT other.user_id
               FROM conversation_members mine
               JOIN conversations c ON c.id = mine.conversation_id
                                    AND c.kind = 'direct' AND c.status = 'accepted'
               JOIN conversation_members other
                 ON other.conversation_id = mine.conversation_id
                AND other.user_id <> mine.user_id
              WHERE mine.user_id = $1
           )
           SELECT s.id, s.user_id, u.display_name, u.avatar_color, u.photo_path,
                  s.kind, s.ciphertext, s.iv, s.file_path, s.file_size,
                  s.audio_ciphertext, s.audio_iv, s.audio_file_path, s.audio_file_size,
                  s.audience, s.created_at, s.expires_at,
                  sk.wrapped_key, sk.wrapped_iv,
                  (sv.viewer_id IS NOT NULL) AS viewed,
                  (sm_me.mentioned_user_id IS NOT NULL) AS mentions_me
             FROM statuses s
             JOIN users u ON u.id = s.user_id
             LEFT JOIN status_keys sk ON sk.status_id = s.id AND sk.viewer_id = $1
             LEFT JOIN status_views sv ON sv.status_id = s.id AND sv.viewer_id = $1
             LEFT JOIN status_mentions sm_me ON sm_me.status_id = s.id AND sm_me.mentioned_user_id = $1
            WHERE s.expires_at > now()
              AND (s.user_id = $1 OR s.user_id IN (SELECT user_id FROM contacts))
              AND sk.wrapped_key IS NOT NULL
            ORDER BY s.created_at DESC""",
        user_id,
    )

    status_ids = [r["id"] for r in rows]
    mentions_by_status: dict[str, list] = {}
    if status_ids:
        mention_rows = await query(
            """SELECT sm.status_id, sm.mentioned_user_id, u.display_name
                 FROM status_mentions sm
                 JOIN users u ON u.id = sm.mentioned_user_id
                WHERE sm.status_id = ANY($1::uuid[])""",
            status_ids,
        )
        for m in mention_rows:
            mentions_by_status.setdefault(m["status_id"], []).append(
                {"userId": m["mentioned_user_id"], "displayName": m["display_name"]}
            )

    return {"statuses": [{
        **shape_status(r),
        "posterId": r["user_id"],
        "posterName": r["display_name"],
        "posterColor": r["avatar_color"],
        "posterPhotoUrl": f"/api/users/{r['user_id']}/photo" if r["photo_path"] else None,
        "isMine": r["user_id"] == user_id,
        "wrappedKey": r["wrapped_key"],
        "wrappedIv": r["wrapped_iv"],
        "mentionsMe": bool(r["mentions_me"]),
        "mentions": mentions_by_status.get(r["id"], []),
    } for r in rows]}


@router.post("/{status_id}/view")
async def view_status(status_id: str, user_id: str = Depends(require_auth)):
    await query(
        """INSERT INTO status_views (status_id, viewer_id)
           SELECT $1, $2 WHERE EXISTS (
             SELECT 1 FROM statuses WHERE id = $1 AND user_id <> $2
           )
           ON CONFLICT (status_id, viewer_id) DO NOTHING""",
        status_id, user_id,
    )
    return {"ok": True}


@router.get("/{status_id}/views")
async def status_views(status_id: str, user_id: str = Depends(require_auth)):
    owns = await one("SELECT 1 FROM statuses WHERE id = $1 AND user_id = $2", status_id, user_id)
    if not owns:
        raise HTTPException(403, "Not your status.")

    rows = await query(
        """SELECT sv.viewer_id, u.display_name, u.avatar_color, u.photo_path, sv.viewed_at
             FROM status_views sv
             JOIN users u ON u.id = sv.viewer_id
            WHERE sv.status_id = $1
            ORDER BY sv.viewed_at DESC""",
        status_id,
    )
    return {"views": [{
        "userId": r["viewer_id"], "displayName": r["display_name"], "avatarColor": r["avatar_color"],
        "photoUrl": f"/api/users/{r['viewer_id']}/photo" if r["photo_path"] else None,
        "viewedAt": r["viewed_at"],
    } for r in rows]}


@router.delete("/{status_id}")
async def delete_status(status_id: str, user_id: str = Depends(require_auth)):
    row = await one("DELETE FROM statuses WHERE id = $1 AND user_id = $2 RETURNING id", status_id, user_id)
    if not row:
        raise HTTPException(404, "Status not found (or not yours).")
    return {"ok": True}
