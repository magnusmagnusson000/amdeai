"""Strip common faster-whisper lead-in hallucinations (silence / click noise)."""
from __future__ import annotations

import re

# YouTube-style phrases often invented on near-silent first chunks
_LEAD_JUNK = re.compile(
    r"^\s*("
    r"thanks?\s+for\s+watching[!.\s]*|"
    r"thank\s+you\s+for\s+watching[!.\s]*|"
    r"subscribe\s*(to\s+my\s+channel)?[!.\s]*|"
    r"like\s+and\s+subscribe[!.\s]*|"
    r"hit\s+the\s+bell[!.\s]*|"
    r"see\s+you\s+next\s+time[!.\s]*"
    r")+",
    re.IGNORECASE,
)
_TRAIL_THANKS = re.compile(
    r"[.\s!]*thank\s+you\.?\s*$",
    re.IGNORECASE,
)

# Common faster-whisper tails on trailing silence (not user speech)
_TRAIL_SILENCE_HALLUCINATIONS: list[re.Pattern[str]] = [
    re.compile(r"\s+(?:it'?s|it is)\s+kind\s+of\s+bad\.?\s*$", re.IGNORECASE),
    re.compile(r"\s+that'?s\s+all\s+folks\.?\s*$", re.IGNORECASE),
    re.compile(
        r"\s+subtitles?\s+by\s+the\s+amara\.org\s+community\.?\s*$",
        re.IGNORECASE,
    ),
]


def _strip_trailing_silence_hallucinations(s: str) -> str:
    t = s.strip()
    if not t:
        return ""
    # Entire segment is a stock hallucination
    if re.fullmatch(
        r"(?:it'?s|it is)\s+kind\s+of\s+bad\.?", t, flags=re.IGNORECASE
    ):
        return ""
    changed = True
    while changed and t:
        changed = False
        for pat in _TRAIL_SILENCE_HALLUCINATIONS:
            nt = pat.sub("", t).strip()
            if nt != t:
                t = nt
                changed = True
                break
    return t


def clean_transcript_piece(text: str) -> str:
    """Remove leading/trailing stock phrases from one STT segment."""
    if not text or not text.strip():
        return ""
    s = text.strip()
    while True:
        m = _LEAD_JUNK.match(s)
        if not m:
            break
        s = s[m.end() :].strip()
    s = _TRAIL_THANKS.sub("", s).strip()
    return _strip_trailing_silence_hallucinations(s)


def clean_full_session_text(text: str) -> str:
    """Final pass on the full joined transcript (handles tails split across chunks)."""
    if not text or not text.strip():
        return ""
    return _strip_trailing_silence_hallucinations(text.strip())
