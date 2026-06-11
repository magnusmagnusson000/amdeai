"""TTS via local Kokoro-82M (CPU-only)."""
from __future__ import annotations

import asyncio
import io
from typing import AsyncIterator

import numpy as np
import soundfile as sf


class KokoroTTS:
    """British English Kokoro voices: bf_emma, bf_isabella, bm_george, bm_lewis."""

    def __init__(self, voice: str = "bf_emma"):
        self.voice = voice
        self._pipeline = None

    def _get_pipeline(self):
        if self._pipeline is None:
            from kokoro import KPipeline  # noqa: PLC0415

            self._pipeline = KPipeline(lang_code="b")
        return self._pipeline

    def _synthesize_sync(self, text: str) -> bytes:
        pipeline = self._get_pipeline()
        chunks: list[np.ndarray] = []
        for item in pipeline(text, voice=self.voice, speed=1.0):
            if hasattr(item, "audio"):
                audio = item.audio
            else:
                # (graphemes, phonemes, audio) tuple
                audio = item[2]
            if audio is not None and len(audio):
                chunks.append(np.asarray(audio, dtype=np.float32))
        if not chunks:
            buf = io.BytesIO()
            sf.write(buf, np.zeros(100, dtype=np.float32), 24000, format="WAV", subtype="PCM_16")
            return buf.getvalue()
        audio_np = np.concatenate(chunks) if len(chunks) > 1 else chunks[0]
        buf = io.BytesIO()
        sf.write(buf, audio_np, 24000, format="WAV", subtype="PCM_16")
        return buf.getvalue()

    async def synthesize_stream(self, text: str) -> AsyncIterator[bytes]:
        loop = asyncio.get_event_loop()
        data = await loop.run_in_executor(None, lambda: self._synthesize_sync(text))
        yield data
