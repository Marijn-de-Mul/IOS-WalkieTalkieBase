from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List
import os
import uuid

app = FastAPI()

AUDIO_DIR = "audio_messages"
os.makedirs(AUDIO_DIR, exist_ok=True)

class Message(BaseModel):
    sender: str
    receiver: str
    filename: str

messages: List[Message] = []

@app.post("/send_message/", response_model=Message)
async def send_message(sender: str, receiver: str, file: UploadFile = File(...)):
    filename = f"{uuid.uuid4()}.wav"
    file_path = os.path.join(AUDIO_DIR, filename)
    
    with open(file_path, "wb") as buffer:
        buffer.write(await file.read())
    
    message = Message(sender=sender, receiver=receiver, filename=filename)
    messages.append(message)
    return message

@app.get("/get_messages/{receiver}", response_model=List[Message])
def get_messages(receiver: str):
    receiver_messages = [msg for msg in messages if msg.receiver == receiver]
    return receiver_messages

@app.get("/download_message/{filename}")
def download_message(filename: str):
    file_path = os.path.join(AUDIO_DIR, filename)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(file_path)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)