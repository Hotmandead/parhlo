# Agent Sidecar Rules (Python 3.12 / Docker)

## Environment & Execution
- Execute all Python package installs and `pytest` runs inside Docker, never on the host Python/Conda environment:
  - `docker compose build`
  - `docker compose run --rm sidecar pytest -v`
  - `docker compose up`
- Dependencies are declared in `agent-sidecar/pyproject.toml` (`google-genai>=2.3.0`, `websockets>=13.0`, `pydantic>=2.9.0`).

## Coding & Protocol Standards
- Use **Pydantic v2** strict discriminated unions in `src/sidecar/schemas.py` (`UpstreamMessage`, `DownstreamMessage`).
- Keep all Gemini Live tool declarations (`highlight_region`, `point_arrow`, `show_step_callout`, `clear_annotations`) configured with `behavior="NON_BLOCKING"` so voice audio stays responsive.
- Coordinate grounding (`src/sidecar/grounding.py`) must clamp Gemini's `0–999` `[ymin, xmin, ymax, xmax]` boxes, normalize inverted bounds, denormalize to pixel coordinates, and snap deterministically to `AXUIElement` frames when confidence exceeds threshold.
- Preserve immediate VAD barge-in handling (`server_content.interrupted == True` -> emit `BargeInMessage`).

## Quality Gate
Before finishing any `agent-sidecar/` change, run:
```bash
docker compose run --rm sidecar pytest -v
```
