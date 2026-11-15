"""Free-tier Gemini Live API (`gemini-3.8-live`) prototype for Parhlo.

Supports:
1. One-shot text/image test (`--prompt "..."`, optional `--image path.png`)
2. Live bidirectional voice + screen/image streaming (`--mic` / default interactive mode):
   - 16 kHz mono PCM microphone capture -> `send_realtime_input(audio=...)`
   - 24 kHz mono PCM speaker playback with instant barge-in queue clear (`interrupted=True`)
   - 1 FPS JPEG screen capture via `mss` + `Pillow` (or `--no-screen` / `--image`)
   - `NON_BLOCKING` `highlight_region` tool call handling + live transcriptions
"""

import argparse
import asyncio
from collections import deque
from io import BytesIO
import os
from pathlib import Path

from google import genai
from google.genai import types
import mss
from PIL import Image
import sounddevice as sd

INPUT_SAMPLE_RATE = 16000
OUTPUT_SAMPLE_RATE = 24000
CHANNELS = 1
MIC_CHUNK_FRAMES = 1600  # 100 ms at 16 kHz


def load_dotenv(path: Path) -> None:
    """Load key=value pairs from a local .env file into os.environ if unset."""
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def encode_jpeg(img: Image.Image, max_width: int = 1280, quality: int = 65) -> bytes:
    """Resize an image preserving aspect ratio and encode it as JPEG bytes."""
    rgb = img.convert("RGB")
    if rgb.width > max_width:
        new_height = int(rgb.height * (max_width / rgb.width))
        rgb = rgb.resize((max_width, new_height), Image.Resampling.LANCZOS)
    buf = BytesIO()
    rgb.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def capture_screen_jpeg() -> bytes:
    """Capture the primary monitor and return compressed JPEG bytes."""
    with mss.mss() as sct:
        monitor = sct.monitors[1]
        shot = sct.grab(monitor)
        img = Image.frombytes("RGB", shot.size, shot.rgb)
    return encode_jpeg(img)


HIGHLIGHT_TOOL = types.Tool(
    function_declarations=[
        types.FunctionDeclaration(
            name="highlight_region",
            description="Highlight a UI region on the user's macOS screen using 0-999 normalized coordinates.",
            behavior=types.Behavior.NON_BLOCKING,
            parameters=types.Schema(
                type=types.Type.OBJECT,
                properties={
                    "box_2d": types.Schema(
                        type=types.Type.ARRAY,
                        items=types.Schema(type=types.Type.INTEGER),
                        description="Bounding box [ymin, xmin, ymax, xmax] in 0-999 range.",
                    ),
                    "label": types.Schema(
                        type=types.Type.STRING,
                        description="Short label for the highlighted UI control.",
                    ),
                },
                required=["box_2d", "label"],
            ),
        )
    ]
)


def build_config() -> types.LiveConnectConfig:
    """Build the LiveConnectConfig for audio, transcriptions, and non-blocking tools."""
    return types.LiveConnectConfig(
        response_modalities=[types.Modality.AUDIO],
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        tools=[HIGHLIGHT_TOOL],
        system_instruction=types.Content(
            parts=[
                types.Part(
                    text=(
                        "You are Parhlo, a concise macOS screen assistant. "
                        "Keep spoken replies brief and helpful. Use highlight_region "
                        "when pointing out UI elements on the user's screen."
                    )
                )
            ]
        ),
    )


async def handle_tool_calls(session, response) -> None:
    """Reply to any non-blocking function calls in a Live API response."""
    if not (response.tool_call and response.tool_call.function_calls):
        return
    for call in response.tool_call.function_calls:
        print(f"\n[tool_call] {call.name}({call.args})")
        await session.send_tool_response(
            function_responses=[
                types.FunctionResponse(
                    id=call.id,
                    name=call.name,
                    response={"status": "rendered"},
                )
            ]
        )


async def run_oneshot(prompt: str, image_path: Path | None) -> None:
    """Send a single text (and optional image) prompt and print transcript + audio stats."""
    client = genai.Client(http_options={"api_version": "v1beta"})
    print("Connecting to gemini-3.8-live...")
    async with client.aio.live.connect(model="gemini-3.8-live", config=build_config()) as session:
        if image_path is not None:
            jpeg_bytes = encode_jpeg(Image.open(image_path))
            print(f"Sending image: {image_path} ({len(jpeg_bytes)} bytes)")
            await session.send_realtime_input(
                video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
            )
            await asyncio.sleep(0.5)

        print(f"Sending prompt: {prompt!r}")
        await session.send_realtime_input(text=prompt)

        audio_bytes = 0
        transcript_chunks: list[str] = []

        async for response in session.receive():
            await handle_tool_calls(session, response)
            content = response.server_content
            if not content:
                continue
            if content.model_turn:
                for part in content.model_turn.parts:
                    if part.inline_data and part.inline_data.data:
                        audio_bytes += len(part.inline_data.data)
            if content.output_transcription and content.output_transcription.text:
                transcript_chunks.append(content.output_transcription.text)
            if content.turn_complete:
                break

        duration_s = audio_bytes / (OUTPUT_SAMPLE_RATE * 2)
        print(f"\n[transcript] {''.join(transcript_chunks).strip()}")
        print(f"[audio] Received {audio_bytes} bytes (~{duration_s:.2f}s of 24 kHz PCM)")


async def run_interactive(use_screen: bool, image_path: Path | None, fps: float) -> None:
    """Stream mic audio and optional screen/image frames bidirectionally until Ctrl+C."""
    client = genai.Client(http_options={"api_version": "v1beta"})
    loop = asyncio.get_running_loop()
    mic_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=32)
    playback_buffer: deque[bytes] = deque()
    playback_remainder = bytearray()

    def mic_callback(indata, frames, time_info, status) -> None:
        chunk = bytes(indata)
        loop.call_soon_threadsafe(_enqueue_drop_oldest, mic_queue, chunk)

    def speaker_callback(outdata, frames, time_info, status) -> None:
        needed = frames * 2  # 16-bit mono
        while len(playback_remainder) < needed and playback_buffer:
            playback_remainder.extend(playback_buffer.popleft())
        if len(playback_remainder) >= needed:
            outdata[:] = playback_remainder[:needed]
            del playback_remainder[:needed]
        else:
            available = len(playback_remainder)
            outdata[:available] = playback_remainder
            outdata[available:] = b"\x00" * (needed - available)
            playback_remainder.clear()

    print("Connecting to gemini-3.8-live...")
    async with client.aio.live.connect(model="gemini-3.8-live", config=build_config()) as session:
        if image_path is not None:
            jpeg_bytes = encode_jpeg(Image.open(image_path))
            await session.send_realtime_input(
                video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
            )
            await asyncio.sleep(0.5)
            print(f"Sent initial image: {image_path} ({len(jpeg_bytes)} bytes)")

        print("Live session active. Speak into your mic (press Ctrl+C to stop).")

        async def send_mic_loop() -> None:
            while True:
                chunk = await mic_queue.get()
                await session.send_realtime_input(
                    audio=types.Blob(data=chunk, mime_type=f"audio/pcm;rate={INPUT_SAMPLE_RATE}")
                )

        async def send_screen_loop() -> None:
            if not use_screen:
                return
            interval = 1.0 / max(0.1, fps)
            while True:
                jpeg_bytes = await asyncio.to_thread(capture_screen_jpeg)
                await session.send_realtime_input(
                    video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg")
                )
                await asyncio.sleep(interval)

        async def receive_loop() -> None:
            async for response in session.receive():
                await handle_tool_calls(session, response)
                content = response.server_content
                if not content:
                    continue
                if content.interrupted is True:
                    playback_buffer.clear()
                    playback_remainder.clear()
                    print("\n[barge-in] Playback cleared")
                if content.input_transcription and content.input_transcription.text:
                    print(f"[you] {content.input_transcription.text}", end="", flush=True)
                if content.output_transcription and content.output_transcription.text:
                    print(f"[gemini] {content.output_transcription.text}", end="", flush=True)
                if content.model_turn:
                    for part in content.model_turn.parts:
                        if part.inline_data and part.inline_data.data:
                            playback_buffer.append(part.inline_data.data)
                if content.turn_complete:
                    print()

        with (
            sd.RawInputStream(
                samplerate=INPUT_SAMPLE_RATE,
                blocksize=MIC_CHUNK_FRAMES,
                channels=CHANNELS,
                dtype="int16",
                callback=mic_callback,
            ),
            sd.RawOutputStream(
                samplerate=OUTPUT_SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=speaker_callback,
            ),
        ):
            tasks = [
                asyncio.create_task(send_mic_loop()),
                asyncio.create_task(send_screen_loop()),
                asyncio.create_task(receive_loop()),
            ]
            try:
                await asyncio.gather(*tasks)
            finally:
                for task in tasks:
                    task.cancel()


def _enqueue_drop_oldest(queue: asyncio.Queue[bytes], item: bytes) -> None:
    if queue.full():
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            pass
    queue.put_nowait(item)


def main() -> None:
    load_dotenv(Path(".env"))
    if not os.environ.get("GEMINI_API_KEY"):
        raise RuntimeError("GEMINI_API_KEY is not set. Add it to .env or export it.")

    parser = argparse.ArgumentParser(description="Parhlo Gemini Live API free-tier prototype")
    parser.add_argument("--prompt", help="Run a one-shot text prompt instead of live mic mode.")
    parser.add_argument("--image", type=Path, help="Optional image file to send as a JPEG frame.")
    parser.add_argument(
        "--no-screen",
        action="store_true",
        help="Disable 1 FPS screen capture in live mic mode.",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=1.0,
        help="Screen capture frame rate in live mic mode (default: 1.0).",
    )
    args = parser.parse_args()

    try:
        if args.prompt:
            asyncio.run(run_oneshot(args.prompt, args.image))
        else:
            asyncio.run(
                run_interactive(
                    use_screen=not args.no_screen,
                    image_path=args.image,
                    fps=args.fps,
                )
            )
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
