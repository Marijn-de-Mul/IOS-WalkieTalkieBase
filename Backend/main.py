from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from typing import List, Dict
import sqlite3
import json

app = FastAPI()

# In-memory SQLite database
def init_db():
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE channels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL
        )
    """)
    cursor.execute("INSERT INTO channels (name) VALUES (?)", ("Default",))  
    conn.commit()
    return conn

db_conn = init_db()

class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, List[WebSocket]] = {}  
        self.channel_senders: Dict[str, WebSocket] = {}  

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
                del self.active_connections[channel]  
            if channel in self.channel_senders and self.channel_senders[channel] == websocket:
                self.channel_senders.pop(channel)
            print(f"Client disconnected from channel {channel}: {websocket.client}")

    async def broadcast(self, data: bytes, channel: str, sender: WebSocket):
        if channel in self.active_connections:
            for connection in self.active_connections[channel]:
                if connection != sender: 
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

@app.get("/api/channels")
async def get_channels():
    cursor = db_conn.cursor()
    cursor.execute("SELECT name FROM channels")
    channels = [row[0] for row in cursor.fetchall()]
    return {"channels": channels}

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
                if data.startswith("new_channel:"):
                    new_channel = data.split("new_channel:")[1]
                    cursor = db_conn.cursor()
                    try:
                        cursor.execute("INSERT INTO channels (name) VALUES (?)", (new_channel,))
                        db_conn.commit()
                        for active_channel in manager.active_connections:
                            for connection in manager.active_connections[active_channel]:
                                await manager.send_message(f"new_channel:{new_channel}", connection)
                        print(f"New channel created: {new_channel}")
                    except sqlite3.IntegrityError:
                        print(f"Channel {new_channel} already exists")
                elif data == "start":
                    if await manager.set_sender(websocket, channel):
                        await manager.send_message("start_ack", websocket)
                    else:
                        await manager.send_message("busy", websocket)
                elif data == "stop":
                    manager.clear_sender(websocket, channel)
                    await manager.send_message("stop_ack", websocket)
                elif data == "join_channel":
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
