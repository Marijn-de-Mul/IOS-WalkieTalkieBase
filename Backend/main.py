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

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)
        if self.current_sender == websocket:
            self.current_sender = None

    async def broadcast(self, data: bytes):
        for connection in self.active_connections:
            await connection.send_bytes(data)

    async def set_sender(self, websocket: WebSocket):
        if self.current_sender is None:
            self.current_sender = websocket
            return True
        return False

    def clear_sender(self, websocket: WebSocket):
        if self.current_sender == websocket:
            self.current_sender = None

manager = ConnectionManager()

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_bytes()
            if manager.current_sender == websocket:
                await manager.broadcast(data)
    except WebSocketDisconnect:
        manager.disconnect(websocket)

@app.websocket("/ws/control")
async def websocket_control(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            if data == "start":
                if await manager.set_sender(websocket):
                    await websocket.send_text("start_ack")
                else:
                    await websocket.send_text("busy")
            elif data == "stop":
                manager.clear_sender(websocket)
                await websocket.send_text("stop_ack")
    except WebSocketDisconnect:
        manager.disconnect(websocket)