from __future__ import annotations

import io
import os
import subprocess
import tempfile
from contextlib import asynccontextmanager
from typing import Literal

import soundfile as sf
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from logging_json import configure_logging, log_event, suppress_uvicorn_health_access_logs
from model import KokoroTTS
from voice_config import BRITISH_VOICES, DEFAULT_VOICE, get_voice_preset, resolve_voice

configure_logging()


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    suppress_uvicorn_health_access_logs()
    yield


app = FastAPI(title="TTS Service", lifespan=_lifespan)
_tts_instances: dict[str, KokoroTTS] = {}


class SpeechRequest(BaseModel):
    model: str = "kokoro-82m"
    input: str = Field(..., min_length=1, max_length=2000)
    voice: str = DEFAULT_VOICE
    response_format: Literal["wav", "pcm", "mp3"] = "pcm"
    speed: float = 1.0


def get_tts(voice: str) -> KokoroTTS:
    if voice not in _tts_instances:
        _tts_instances[voice] = KokoroTTS(voice=voice)
    return _tts_instances[voice]


def _wav_to_pcm(wav_bytes: bytes) -> bytes:
    data, _sample_rate = sf.read(io.BytesIO(wav_bytes), dtype="int16")
    return data.tobytes()


def _wav_to_mp3(wav_bytes: bytes) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as inp:
        inp.write(wav_bytes)
        inp_path = inp.name
    out_path = f"{inp_path}.mp3"
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                inp_path,
                "-codec:a",
                "libmp3lame",
                "-qscale:a",
                "2",
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


def _response_for_format(wav_bytes: bytes, response_format: str) -> tuple[bytes, str]:
    if response_format == "wav":
        return wav_bytes, "audio/wav"
    if response_format == "pcm":
        return _wav_to_pcm(wav_bytes), "audio/pcm"
    if response_format == "mp3":
        return _wav_to_mp3(wav_bytes), "audio/mpeg"
    raise HTTPException(status_code=422, detail=f"Unsupported response_format: {response_format}")


@app.get("/health")
async def health():
    return {"status": "ok", "model": "kokoro-82m", "default_voice": DEFAULT_VOICE}


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{"id": "kokoro-82m", "object": "model", "owned_by": "telecom-tts"}],
    }


@app.post("/v1/audio/speech")
async def audio_speech(body: SpeechRequest, request: Request):
    if not body.input.strip():
        raise HTTPException(status_code=422, detail="text must not be empty")
    voice = resolve_voice(body.voice)
    try:
        get_voice_preset(voice)
    except KeyError as e:
        raise HTTPException(status_code=422, detail=f"Unknown voice: {body.voice}") from e
    rid = (
        request.headers.get("x-request-id")
        or request.headers.get("X-Request-ID")
        or ""
    ).strip() or "unknown"
    log_event(
        "tts_openai_speech_start",
        rid,
        extra={"text_len": len(body.input), "voice": voice, "format": body.response_format},
    )
    tts = get_tts(voice)
    media_types = {"pcm": "audio/pcm", "wav": "audio/wav", "mp3": "audio/mpeg"}
    media_type = media_types[body.response_format]

    async def generator():
        async for chunk in tts.synthesize_stream(body.input):
            payload, _ = _response_for_format(chunk, body.response_format)
            yield payload
        log_event("tts_openai_speech_end", rid, extra={"voice": voice})

    return StreamingResponse(generator(), media_type=media_type)


@app.get("/tts/stream")
async def tts_stream(
    request: Request,
    text: str = Query(..., min_length=1, max_length=2000),
    voice: str = Query(DEFAULT_VOICE),
):
    if not text.strip():
        raise HTTPException(status_code=422, detail="text must not be empty")
    kokoro_voice = resolve_voice(voice)
    try:
        get_voice_preset(kokoro_voice)
    except KeyError as e:
        raise HTTPException(status_code=422, detail=f"Unknown voice: {voice}") from e
    rid = (
        request.headers.get("x-request-id")
        or request.headers.get("X-Request-ID")
        or ""
    ).strip() or "unknown"
    log_event(
        "tts_stream_start",
        rid,
        extra={"text_len": len(text), "voice": kokoro_voice},
    )
    tts = get_tts(kokoro_voice)

    async def generator():
        n = 0
        async for chunk in tts.synthesize_stream(text):
            n += 1
            yield chunk
        log_event("tts_stream_end", rid, extra={"chunks": n})

    return StreamingResponse(generator(), media_type="audio/wav")


@app.get("/voices")
async def list_voices():
    return [{"id": v.id, "gender": v.gender, "description": v.description} for v in BRITISH_VOICES]
