from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from typing import List, Dict, Optional
import json

app = FastAPI()

class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, List[WebSocket]] = {}  # channel: [websocket]
        self.channel_senders: Dict[str, WebSocket] = {}  # channel: websocket

    async def connect(self, websocket: WebSocket, channel: str):
        await websocket.accept()
        if channel not in self.active_connections:
            self.active_connections[channel] = []
        self.active_connections[channel].append(websocket)
        print(f"Client connected to channel {channel}: {websocket.client}")

    def disconnect(self, websocket: WebSocket, channel: str):
        if channel in self.active_connections:
            self.active_connections[channel].remove(websocket)
            if not self.active_connections[channel]:
                del self.active_connections[channel]  # Remove empty channel
            if channel in self.channel_senders and self.channel_senders[channel] == websocket:
                self.channel_senders.pop(channel)
            print(f"Client disconnected from channel {channel}: {websocket.client}")

    async def broadcast(self, data: bytes, channel: str, sender: WebSocket):
        if channel in self.active_connections:
            for connection in self.active_connections[channel]:
                if connection != sender:  # Don't send back to the sender
                    try:
                        await connection.send_bytes(data)
                    except Exception as e:
                        print(f"Error broadcasting to {connection.client}: {e}")
        print(f"Broadcasted data: {len(data)} bytes to {len(self.active_connections.get(channel, []))} clients in channel {channel}")

    async def set_sender(self, websocket: WebSocket, channel: str):
        if channel not in self.channel_senders:
            self.channel_senders[channel] = websocket
            print(f"Sender set for channel {channel}: {websocket.client}")
            return True
        return False

    def clear_sender(self, websocket: WebSocket, channel: str):
        if channel in self.channel_senders and self.channel_senders[channel] == websocket:
            self.channel_senders.pop(channel)
            print(f"Sender cleared for channel {channel}: {websocket.client}")

    async def send_message(self, message: str, websocket: WebSocket):
        try:
            await websocket.send_text(message)
        except Exception as e:
            print(f"Error sending message to {websocket.client}: {e}")

manager = ConnectionManager()

@app.websocket("/ws/{channel}")
async def websocket_endpoint(websocket: WebSocket, channel: str):
    await manager.connect(websocket, channel)
    try:
        while True:
            try:
                message = await websocket.receive()
            except RuntimeError as e:
                if "Cannot call" in str(e):
                    break
                else:
                    raise e
            if "bytes" in message:
                data = message["bytes"]
                print(f"Received data: {len(data)} bytes from {websocket.client} in channel {channel}")
                if channel in manager.channel_senders and manager.channel_senders[channel] == websocket:
                    print(f"Broadcasting data from sender: {websocket.client} in channel {channel}")
                    await manager.broadcast(data, channel, websocket)
                else:
                    print(f"Received data from non-sender: {websocket.client} in channel {channel}")
            elif "text" in message:
                text_data = message["text"]
                try:
                    data = json.loads(text_data)
                    if "type" in data:
                        if data["type"] == "iceCandidate" or data["type"] == "offer" or data["type"] == "answer":
                            # Forward signaling messages to other clients in the channel
                            for connection in manager.active_connections[channel]:
                                if connection != websocket:
                                    await manager.send_message(text_data, connection)
                        else:
                            print(f"Unknown message type: {data['type']}")
                except json.JSONDecodeError:
                    print(f"Received non-JSON text data: {text_data}")
    except WebSocketDisconnect:
        manager.disconnect(websocket, channel)
    finally:
        manager.disconnect(websocket, channel)

@app.websocket("/ws/control/{channel}")
async def websocket_control(websocket: WebSocket, channel: str):
    await manager.connect(websocket, channel)
    try:
        while True:
            try:
                message = await websocket.receive()
            except RuntimeError as e:
                if "Cannot call" in str(e):
                    break
                else:
                    raise e
            if "text" in message:
                data = message["text"]
                print(f"Received control message: {data} from {websocket.client} in channel {channel}")
                if data == "start":
                    if await manager.set_sender(websocket, channel):
                        await manager.send_message("start_ack", websocket)
                    else:
                        await manager.send_message("busy", websocket)
                elif data == "stop":
                    manager.clear_sender(websocket, channel)
                    await manager.send_message("stop_ack", websocket)
                elif data == "join_channel":
                    # Notify other peers in the channel about the new peer
                    for connection in manager.active_connections[channel]:
                        if connection != websocket:
                            await manager.send_message(f"peer_joined:{websocket.client}", connection)
            elif "bytes" in message:
                data = message["bytes"]
                print(f"Received binary data on control channel: {len(data)} bytes from {websocket.client} in channel {channel}")
                if channel in manager.channel_senders and manager.channel_senders[channel] == websocket:
                    await manager.broadcast(data, channel, websocket)
                else:
                    print(f"Binary data received from non-sender: {websocket.client} in channel {channel}")
    except WebSocketDisconnect:
        manager.disconnect(websocket, channel)
    finally:
        manager.disconnect(websocket, channel)
