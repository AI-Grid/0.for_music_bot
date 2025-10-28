"""
System: Suno Automation Backend
Module: Chat API Routes
File URL: backend/api/chat/routes.py
Purpose: Provide an OpenAI-compatible chat completion endpoint secured by API key and Discord password validation.
"""

from __future__ import annotations

import hmac
import os
import uuid
from datetime import datetime, timezone
from typing import List

from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/v1/chat", tags=["chat"])


class ChatMessage(BaseModel):
    """A single chat message in OpenAI-compatible format."""

    role: str = Field(description="Role of the message author (user, assistant, system).")
    content: str = Field(description="Plain-text content of the message.")


class ChatCompletionRequest(BaseModel):
    """Request payload for chat completions."""

    model: str = Field(description="Model name requested by the client.")
    messages: List[ChatMessage] = Field(description="Chronological list of chat messages.")
    temperature: float | None = Field(default=1.0, description="Sampling temperature for compatibility with OpenAI API.")


class ChatCompletionChoice(BaseModel):
    """Single choice returned by the chat completion endpoint."""

    index: int
    message: ChatMessage
    finish_reason: str = Field(default="stop")


class ChatCompletionUsage(BaseModel):
    """Token usage metadata."""

    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class ChatCompletionResponse(BaseModel):
    """Response payload for chat completions."""

    id: str
    object: str = Field(default="chat.completion")
    created: int
    model: str
    choices: List[ChatCompletionChoice]
    usage: ChatCompletionUsage


def _require_configured_api_key() -> str:
    """Fetch the configured API key or raise an error when missing."""

    configured_key = os.getenv("CHAT_API_KEY")
    if not configured_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="CHAT_API_KEY environment variable is not configured.",
        )
    return configured_key


def _require_api_key(request: Request) -> None:
    """Validate the Authorization header against the configured API key."""

    configured_key = _require_configured_api_key()
    authorization_header = request.headers.get("authorization", "")
    if not authorization_header.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing bearer token in Authorization header.",
        )

    provided_key = authorization_header.split(" ", 1)[1].strip()
    if not provided_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Empty bearer token provided.",
        )

    if not hmac.compare_digest(provided_key, configured_key):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid API key provided.",
        )


def _require_discord_password(request: Request) -> None:
    """Validate the optional Discord password when the request originates from a bot."""

    is_discord_request = request.headers.get("x-discord-bot", "").lower() in {"1", "true", "yes"}
    if not is_discord_request:
        return

    configured_password = os.getenv("DISCORD_BOT_PASSWORD", "marty")
    provided_password = request.headers.get("x-discord-password", "")

    if not provided_password:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Discord password is required for bot requests.",
        )

    if not hmac.compare_digest(provided_password, configured_password):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid Discord bot password provided.",
        )


def _extract_user_message(messages: List[ChatMessage]) -> str:
    """Return the most recent user message or raise when missing."""

    for message in reversed(messages):
        if message.role.lower() == "user" and message.content.strip():
            return message.content.strip()

    raise HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail="At least one user message with content is required.",
    )


def _build_completion_content(user_prompt: str, model_name: str) -> str:
    """Generate a deterministic assistant response describing the backend capabilities."""

    summary_lines = [
        "This is the Suno Automation backend chat interface.",
        "I can orchestrate music automation flows and coordinate with the PHP gateway.",
        f"You asked: {user_prompt}",
        f"Model hint: {model_name}",
        "For Discord access include the password 'marty' via the gateway.",
    ]
    return "\n".join(summary_lines)


def _estimate_token_usage(prompt: str, completion: str) -> ChatCompletionUsage:
    """Provide a rough token usage estimate compatible with OpenAI responses."""

    prompt_tokens = max(len(prompt.split()), 1)
    completion_tokens = max(len(completion.split()), 1)
    total_tokens = prompt_tokens + completion_tokens

    return ChatCompletionUsage(
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
    )


@router.post("/completions", response_model=ChatCompletionResponse)
async def create_chat_completion(request: Request, payload: ChatCompletionRequest) -> ChatCompletionResponse:
    """Handle OpenAI-compatible chat completion requests."""

    _require_api_key(request)
    _require_discord_password(request)

    user_prompt = _extract_user_message(payload.messages)
    completion_text = _build_completion_content(user_prompt, payload.model)
    usage = _estimate_token_usage(user_prompt, completion_text)
    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created_timestamp = int(datetime.now(tz=timezone.utc).timestamp())

    choice = ChatCompletionChoice(
        index=0,
        message=ChatMessage(role="assistant", content=completion_text),
        finish_reason="stop",
    )

    return ChatCompletionResponse(
        id=completion_id,
        created=created_timestamp,
        model=payload.model,
        choices=[choice],
        usage=usage,
    )
