"""WebSocket server bridging macos-app with GeminiLiveSessionManager."""

import asyncio
import logging
import os

from pydantic import TypeAdapter, ValidationError
import websockets
from websockets.asyncio.server import ServerConnection

from sidecar.live_session import GeminiLiveSessionManager
from sidecar.schemas import DownstreamMessage, UpstreamMessage

UPSTREAM_ADAPTER: TypeAdapter[UpstreamMessage] = TypeAdapter(UpstreamMessage)

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


async def handle_connection(websocket: ServerConnection) -> None:
    """Handle a single macos-app WebSocket client lifecycle."""
    logger.info("Client connected from %s", websocket.remote_address)

    async def emit(message: DownstreamMessage) -> None:
        await websocket.send(message.model_dump_json())

    manager = GeminiLiveSessionManager(emit=emit)

    try:
        async for raw_message in websocket:
            if not isinstance(raw_message, str):
                logger.warning("Ignoring non-text WebSocket frame")
                continue
            try:
                parsed = UPSTREAM_ADAPTER.validate_json(raw_message)
            except ValidationError as exc:
                logger.warning("Invalid upstream payload: %s", exc)
                continue
            await manager.handle_upstream(parsed)
    except websockets.exceptions.ConnectionClosed:
        logger.info("Client disconnected")
    finally:
        await manager.stop()


async def run_server(host: str | None = None, port: int | None = None) -> None:
    """Start the sidecar WebSocket server and serve forever."""
    bind_host = host or os.environ.get("SIDECAR_HOST", "0.0.0.0")
    bind_port = port or int(os.environ.get("SIDECAR_PORT", "8765"))
    logger.info("Starting Parhlo sidecar WebSocket server on ws://%s:%d", bind_host, bind_port)
    async with websockets.serve(handle_connection, bind_host, bind_port, max_size=8 * 1024 * 1024):
        await asyncio.Future()


def main() -> None:
    """CLI entrypoint for `python -m sidecar.server`."""
    try:
        asyncio.run(run_server())
    except KeyboardInterrupt:
        logger.info("Sidecar server stopped")


if __name__ == "__main__":
    main()
