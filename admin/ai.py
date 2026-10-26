"""Calls a hosted AI with the key saved on the Settings page.

Providers: "openai" (also Groq, OpenRouter, Together… through a base URL),
"anthropic", "gemini". Errors never contain the API key.
"""
import httpx

DEFAULTS = {
    "openai": {"model": "gpt-4o-mini", "base_url": "https://api.openai.com/v1"},
    "anthropic": {"model": "claude-haiku-5-5", "base_url": "https://api.anthropic.com/v1"},
    "gemini": {"model": "gemini-2.0-flash", "base_url": "https://generativelanguage.googleapis.com/v1beta"},
}


class AIError(Exception):
    pass


def model_for(cfg: dict) -> str:
    return cfg.get("ai_model") or DEFAULTS[cfg["ai_provider"]]["model"]


def ready(cfg: dict) -> bool:
    return bool(cfg.get("ai_key") and cfg.get("ai_provider") in DEFAULTS)


async def chat(cfg: dict, system: str, user: str, timeout: int = 40, max_tokens: int = 300) -> str:
    if not ready(cfg):
        raise AIError("Save an AI provider and key first.")
    provider, key = cfg["ai_provider"], cfg["ai_key"]
    base = (cfg.get("ai_base_url") or DEFAULTS[provider]["base_url"]).rstrip("/")
    model = model_for(cfg)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            if provider == "openai":
                msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": user}]
                res = await client.post(f"{base}/chat/completions", headers={"Authorization": f"Bearer {key}"},
                                        json={"model": model, "messages": msgs, "max_tokens": max_tokens})
            elif provider == "anthropic":
                body = {"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": user}]}
                if system:
                    body["system"] = system
                res = await client.post(f"{base}/messages", headers={"x-api-key": key, "anthropic-version": "2023-06-01"}, json=body)
            else:
                body = {"contents": [{"role": "user", "parts": [{"text": user}]}],
                        "generationConfig": {"maxOutputTokens": max_tokens}}
                if system:
                    body["systemInstruction"] = {"parts": [{"text": system}]}
                res = await client.post(f"{base}/models/{model}:generateContent", headers={"x-goog-api-key": key}, json=body)
    except httpx.RequestError as err:
        raise AIError(f"Could not reach the {provider} API ({type(err).__name__}).") from None

    try:
        data = res.json()
    except ValueError:
        data = {}
    if res.status_code != 200:
        err = data.get("error") if isinstance(data, dict) else None
        msg = err.get("message") if isinstance(err, dict) else (err if isinstance(err, str) else None)
        raise AIError(f"{provider} said {res.status_code}: {str(msg or 'request failed')[:300]}")
    try:
        if provider == "openai":
            text = data["choices"][0]["message"]["content"]
        elif provider == "anthropic":
            text = "".join(b.get("text", "") for b in data["content"] if b.get("type") == "text")
        else:
            text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])
    except (KeyError, IndexError, TypeError):
        raise AIError(f"Unexpected answer from {provider}.") from None
    text = (text or "").strip()
    if not text:
        raise AIError(f"{provider} returned an empty answer.")
    return text
