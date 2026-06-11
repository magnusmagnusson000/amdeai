"""STT via faster-whisper (CPU/GPU friendly)."""
from __future__ import annotations

import os
import time
from dataclasses import dataclass

import numpy as np

MODEL_NAME = "medium"


@dataclass
class TranscriptionResult:
    text: str
    confidence: float
    latency_ms: float


def _beam_size() -> int:
    try:
        return max(1, int(os.environ.get("WHISPER_BEAM_SIZE", "5")))
    except ValueError:
        return 5


def _language() -> str:
    return (os.environ.get("WHISPER_LANGUAGE") or "en").strip() or "en"


def _device() -> str:
    return (os.environ.get("WHISPER_DEVICE") or "auto").strip() or "auto"


def _compute_type() -> str:
    return (os.environ.get("WHISPER_COMPUTE_TYPE") or "default").strip() or "default"


class ParakeetSTT:
    """CPU-friendly STT backend using faster-whisper."""

    MODEL_NAME = "faster-whisper"

    def __init__(self, model_path: str | None = None):
        from faster_whisper import WhisperModel  # noqa: PLC0415

        size = model_path or os.environ.get("WHISPER_MODEL") or "medium"
        self._model = WhisperModel(
            size,
            device=_device(),
            compute_type=_compute_type(),
        )

    def transcribe(self, audio_bytes: bytes, sample_rate: int = 16000) -> TranscriptionResult:
        if not audio_bytes:
            raise ValueError("Audio input is empty")
        audio_np = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        t0 = time.perf_counter()
        try:
            no_speech = float(os.environ.get("WHISPER_NO_SPEECH_THRESHOLD", "0.78"))
        except ValueError:
            no_speech = 0.78
        try:
            log_prob_floor = float(os.environ.get("WHISPER_LOG_PROB_FLOOR", "-1.05"))
        except ValueError:
            log_prob_floor = -1.05
        segments, _ = self._model.transcribe(
            np.asarray(audio_np, dtype=np.float32),
            language=_language(),
            beam_size=_beam_size(),
            vad_filter=True,
            no_speech_threshold=no_speech,
            compression_ratio_threshold=2.4,
            log_prob_threshold=log_prob_floor,
        )
        parts: list[str] = []
        for s in segments:
            lp = getattr(s, "avg_logprob", None)
            if lp is not None and lp < log_prob_floor:
                continue
            t = (s.text or "").strip()
            if t:
                parts.append(s.text)
        text = "".join(parts).strip()
        latency_ms = (time.perf_counter() - t0) * 1000
        return TranscriptionResult(text=text or "", confidence=0.95, latency_ms=latency_ms)
