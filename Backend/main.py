from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from typing import List, Optional

app = FastAPI()

class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []
        self.current_sender: Optional[WebSocket] = None

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
        print(f"Client connected: {websocket.client}")

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)
        if self.current_sender == websocket:
            self.current_sender = None
        print(f"Client disconnected: {websocket.client}")

    async def broadcast(self, data: bytes):
        for connection in self.active_connections:
            await connection.send_bytes(data)
        print(f"Broadcasted data: {len(data)} bytes to {len(self.active_connections)} clients")

    async def set_sender(self, websocket: WebSocket):
        if self.current_sender is None:
            self.current_sender = websocket
            print(f"Sender set: {websocket.client}")
            return True
        return False

    def clear_sender(self, websocket: WebSocket):
        if self.current_sender == websocket:
            self.current_sender = None
            print(f"Sender cleared: {websocket.client}")

manager = ConnectionManager()

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_bytes()
            print(f"Received data: {len(data)} bytes from {websocket.client}")
            if manager.current_sender == websocket:
                print(f"Broadcasting data from sender: {websocket.client}")
                await manager.broadcast(data)
            else:
                print(f"Received data from non-sender: {websocket.client}")
    except WebSocketDisconnect:
        manager.disconnect(websocket)

@app.websocket("/ws/control")
async def websocket_control(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            message = await websocket.receive()
            if "text" in message:
                data = message["text"]
                print(f"Received control message: {data} from {websocket.client}")
                if data == "start":
                    if await manager.set_sender(websocket):
                        await websocket.send_text("start_ack")
                    else:
                        await websocket.send_text("busy")
                elif data == "stop":
                    manager.clear_sender(websocket)
                    await websocket.send_text("stop_ack")
            elif "bytes" in message:
                # If binary data arrives on the control connection and this is the sender, broadcast it.
                data = message["bytes"]
                print(f"Received binary data on control channel: {len(data)} bytes from {websocket.client}")
                if manager.current_sender == websocket:
                    await manager.broadcast(data)
                else:
                    print(f"Binary data received from non-sender: {websocket.client}")
    except WebSocketDisconnect:
        manager.disconnect(websocket)