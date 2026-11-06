"""Tests for the /ai/assist OpenRouter proxy."""

import os

import pytest
import respx
from httpx import Response

import main


@pytest.fixture
def openrouter_key(monkeypatch):
    monkeypatch.setattr(main, "OPENROUTER_API_KEY", "test-key")
    yield


@pytest.mark.asyncio
async def test_ai_assist_requires_session(async_client):
    response = await async_client.post(
        "/ai/assist", json={"action": "summarize", "text": "texto"}
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ai_assist_needs_key(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.post(
        "/ai/assist",
        json={"action": "summarize", "text": "texto"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 503


@pytest.mark.asyncio
@respx.mock
async def test_ai_assist_calls_openrouter(
    async_client, extensionista_session, respx_mock, openrouter_key
):
    token, _ = extensionista_session
    call = respx_mock.post("https://openrouter.ai/api/v1/chat/completions").mock(
        return_value=Response(
            200,
            json={
                "choices": [
                    {"message": {"content": "Resumo gerado pela IA."}}
                ]
            },
        )
    )
    response = await async_client.post(
        "/ai/assist",
        json={"action": "summarize", "text": "Texto longo do campo."},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["result"] == "Resumo gerado pela IA."
    sent = call.calls.last.request
    assert sent.headers["Authorization"] == "Bearer test-key"


@pytest.mark.asyncio
async def test_ai_assist_rejects_unknown_action(
    async_client, extensionista_session, openrouter_key
):
    token, _ = extensionista_session
    response = await async_client.post(
        "/ai/assist",
        json={"action": "hacker", "text": "x"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_ai_assist_rate_limited(
    async_client, extensionista_session, openrouter_key
):
    token, _ = extensionista_session
    import time

    main._AI_RATE.clear()
    user = "extensionista.test"
    main._AI_RATE[user] = [time.monotonic()] * main._AI_RATE_MAX
    response = await async_client.post(
        "/ai/assist",
        json={"action": "summarize", "text": "x"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 429
    main._AI_RATE.clear()
