"""STT service with WebSocket streaming and OpenAI-compatible REST adapter."""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import tempfile
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, UploadFile, WebSocket, WebSocketDisconnect

from logging_json import configure_logging, log_event, suppress_uvicorn_health_access_logs
from model import ParakeetSTT
from transcript_clean import clean_full_session_text, clean_transcript_piece

configure_logging()

_stt_warm: bool = False


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    global _stt_warm
    suppress_uvicorn_health_access_logs()
    if os.getenv("SKIP_STT_WARMUP", "").lower() in ("1", "true", "yes"):
        log_event("stt_warmup_skip", request_id="stt-warmup")
        _stt_warm = False
    else:
        log_event("stt_warmup_start", request_id="stt-warmup")
        await asyncio.to_thread(get_stt)
        _stt_warm = True
        log_event("stt_warmup_done", request_id="stt-warmup")
    yield


app = FastAPI(title="STT Service", lifespan=_lifespan)
_stt: ParakeetSTT | None = None


def get_stt() -> ParakeetSTT:
    global _stt
    if _stt is None:
        _stt = ParakeetSTT(model_path=os.environ.get("WHISPER_MODEL", "medium"))
    return _stt


def _convert_to_pcm16(audio_bytes: bytes) -> bytes:
    """Convert arbitrary audio to PCM16 mono @ 16 kHz using ffmpeg."""
    with tempfile.NamedTemporaryFile(suffix=".audio", delete=False) as inp:
        inp.write(audio_bytes)
        inp_path = inp.name
    out_path = f"{inp_path}.pcm"
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                inp_path,
                "-f",
                "s16le",
                "-acodec",
                "pcm_s16le",
                "-ar",
                "16000",
                "-ac",
                "1",
                out_path,
            ],
            check=True,
            capture_output=True,
        )
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        if os.path.exists(inp_path):
            os.unlink(inp_path)
        if os.path.exists(out_path):
            os.unlink(out_path)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model": "faster-whisper",
        "warm": _stt_warm,
    }


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{"id": "whisper-1", "object": "model", "owned_by": "telecom-stt"}],
    }


@app.post("/v1/audio/transcriptions")
async def transcribe_file(
    file: UploadFile = File(...),
    model: str = Form("whisper-1"),
):
    del model
    audio_bytes = await file.read()
    if not audio_bytes:
        return {"text": ""}
    pcm_bytes = await asyncio.to_thread(_convert_to_pcm16, audio_bytes)
    result = await asyncio.to_thread(get_stt().transcribe, pcm_bytes)
    text = clean_transcript_piece(result.text)
    log_event(
        "stt_openai_transcription",
        request_id="openai-stt",
        extra={"text_len": len(text), "latency_ms": result.latency_ms},
    )
    return {"text": text}


# ~1s PCM16 mono @ 16kHz; first flush waits longer to avoid click+silence hallucinations
CHUNK_THRESHOLD = int(os.getenv("STT_CHUNK_BYTES", str(16000 * 2 * 1)))
FIRST_CHUNK_THRESHOLD = int(
    os.getenv("STT_FIRST_CHUNK_BYTES", str(16000 * 2 * 2))
)  # 2s before first interim transcribe
LEAD_DISCARD_BYTES = int(os.getenv("STT_LEAD_DISCARD_BYTES", str(16000 * 2)))  # drop ~0.5s after connect


def _ws_request_id(ws: WebSocket) -> str:
    h = ws.headers.get("x-request-id") or ws.headers.get("X-Request-ID") or ""
    return h.strip() or "unknown"


def _normalize_phrase(parts: list[str]) -> str:
    return " ".join(p for p in (x.strip() for x in parts) if p)


async def transcribe_ws(ws: WebSocket):
    await ws.accept()
    request_id = _ws_request_id(ws)
    log_event("stt_session_start", request_id=request_id)
    buffer = bytearray()
    stt = get_stt()
    accumulated: list[str] = []
    config_logged = False
    lead_left = LEAD_DISCARD_BYTES
    first_chunk_done = False

    async def flush_chunk() -> None:
        nonlocal first_chunk_done
        if not buffer:
            return
        result = stt.transcribe(bytes(buffer))
        buffer.clear()
        piece = clean_transcript_piece(result.text)
        first_chunk_done = True
        if piece:
            accumulated.append(piece)
        await ws.send_json({
            "text": piece,
            "confidence": result.confidence,
            "latency_ms": result.latency_ms,
            "is_final": False,
        })

    async def send_session_end(full_text: str) -> None:
        log_event(
            "stt_transcript_final",
            request_id=request_id,
            extra={"text_len": len(full_text), "text": full_text[:2000]},
        )
        await ws.send_json({
            "text": full_text,
            "confidence": 0.95,
            "latency_ms": 0,
            "is_final": True,
        })

    try:
        while True:
            msg = await ws.receive()
            if msg.get("type") == "websocket.disconnect":
                break
            if "text" in msg and msg["text"] is not None:
                try:
                    body = json.loads(msg["text"])
                except json.JSONDecodeError:
                    continue
                if body.get("type") == "config" and not config_logged:
                    config_logged = True
                    log_event(
                        "stt_client_config",
                        request_id=request_id,
                        extra={
                            "sample_rate": body.get("sample_rate"),
                            "source_rate": body.get("source_rate"),
                        },
                    )
                    continue
                if body.get("type") == "end":
                    if buffer:
                        result = stt.transcribe(bytes(buffer))
                        buffer.clear()
                        piece = clean_transcript_piece(result.text)
                        if piece:
                            accumulated.append(piece)
                    full_text = clean_full_session_text(_normalize_phrase(accumulated))
                    await send_session_end(full_text)
                continue
            if "bytes" in msg and msg["bytes"] is not None:
                data = msg["bytes"]
                if not data:
                    await ws.send_json({"error": "Empty audio chunk received"})
                    continue
                if lead_left > 0:
                    n = min(lead_left, len(data))
                    data = data[n:]
                    lead_left -= n
                    if not data:
                        continue
                buffer.extend(data)
                need = FIRST_CHUNK_THRESHOLD if not first_chunk_done else CHUNK_THRESHOLD
                if len(buffer) >= need:
                    await flush_chunk()
    except WebSocketDisconnect:
        if buffer:
            result = stt.transcribe(bytes(buffer))
            piece = clean_transcript_piece(result.text)
            if piece:
                accumulated.append(piece)
            full_text = clean_full_session_text(_normalize_phrase(accumulated))
            if full_text:
                try:
                    await send_session_end(full_text)
                except Exception:
                    pass
    finally:
        log_event("stt_session_end", request_id=request_id)


@app.websocket("/ws/transcribe")
async def transcribe_ws_route(ws: WebSocket):
    await transcribe_ws(ws)
