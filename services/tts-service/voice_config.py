from dataclasses import dataclass


@dataclass
class VoicePreset:
    id: str
    locale: str
    gender: str
    description: str


BRITISH_VOICES = [
    VoicePreset("bf_emma", "en-GB", "female", "Emma — warm, clear British female"),
    VoicePreset("bf_isabella", "en-GB", "female", "Isabella — expressive British female"),
    VoicePreset("bm_george", "en-GB", "male", "George — authoritative British male"),
    VoicePreset("bm_lewis", "en-GB", "male", "Lewis — casual British male"),
]

_VOICE_MAP = {v.id: v for v in BRITISH_VOICES}
DEFAULT_VOICE = "bf_emma"

# Map OpenAI / telecom blueprint voice names to Kokoro presets.
OPENAI_VOICE_MAP = {
    "aiden": "bf_emma",
    "alloy": "bf_emma",
    "echo": "bm_george",
    "fable": "bf_isabella",
    "onyx": "bm_lewis",
    "nova": "bf_isabella",
    "shimmer": "bf_emma",
}


def get_voice_preset(voice_id: str = DEFAULT_VOICE) -> VoicePreset:
    return _VOICE_MAP[voice_id]


def resolve_voice(voice: str | None) -> str:
    if not voice:
        return DEFAULT_VOICE
    key = voice.strip().lower()
    if key in OPENAI_VOICE_MAP:
        return OPENAI_VOICE_MAP[key]
    if key in _VOICE_MAP:
        return key
    return DEFAULT_VOICE
