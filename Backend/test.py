import asyncio
import sys
import websockets
import sounddevice as sd
import numpy as np
from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QPushButton, QLabel, QTextEdit
from PyQt5.QtCore import Qt, QThread, pyqtSignal, QObject

class EventLoopThread(QThread):
    """
    Thread that starts and runs an asyncio event loop forever.
    """
    def __init__(self):
        super().__init__()
        self.loop = None

    def run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def stop_loop(self):
        if self.loop is not None:
            self.loop.call_soon_threadsafe(self.loop.stop)

class LogEmitter(QObject):
    log_message = pyqtSignal(str)

class WebSocketClient(QWidget):
    def __init__(self, loop_thread: EventLoopThread):
        super().__init__()
        self.loop_thread = loop_thread
        self.loop = loop_thread.loop
        self.log_emitter = LogEmitter()
        self.log_emitter.log_message.connect(self.on_log_message)

        self.initUI()

        # Use single connection (control endpoint) for both control and audio.
        self.uri = "ws://walkietalkie.backend.marijndemul.nl/ws/control"
        self.is_recording = False
        self.is_receiving = False

    def initUI(self):
        self.setWindowTitle("WebSocket Test Client")
        self.layout = QVBoxLayout()

        self.status_label = QLabel("Idle", self)
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setStyleSheet("font-size: 16px;")
        self.layout.addWidget(self.status_label)

        self.text_area = QTextEdit(self)
        self.text_area.setReadOnly(True)
        self.layout.addWidget(self.text_area)

        self.send_button = QPushButton("Press to Talk", self)
        self.send_button.setStyleSheet("background-color: green; color: white; font-size: 16px; height: 50px;")
        self.send_button.clicked.connect(self.toggle_recording)
        self.layout.addWidget(self.send_button)

        self.setLayout(self.layout)

    def log(self, message: str):
        self.log_emitter.log_message.emit(message)

    def on_log_message(self, message: str):
        self.text_area.append(message)

    async def connect(self):
        # Connect to the control endpoint, which will be used for both control and audio.
        self.websocket = await websockets.connect(self.uri)
        self.log("Connected to WebSocket (control endpoint)")

    async def send_control_message(self, message):
        self.log(f"Sending control message: {message}")
        await self.websocket.send(message)
        response = await self.websocket.recv()
        self.log(f"Control response: {response}")
        return response

    async def send_audio(self, audio_data):
        await self.websocket.send(audio_data)
        self.log(f"Sent audio data: {len(audio_data)} bytes")

    async def receive_audio(self):
        while self.is_recording:
            try:
                # The unified connection will receive both control (text) and audio (bytes).
                message = await self.websocket.recv()
            except Exception as e:
                self.log(f"Error receiving audio: {e}")
                break
            # If we received binary data, play it.
            if isinstance(message, bytes):
                audio_data = np.frombuffer(message, dtype=np.int16)
                sd.play(audio_data, samplerate=44100)
                self.log(f"Received and played audio data: {len(message)} bytes")
            self.update_receiving_status(True)
            await asyncio.sleep(0.1)
            self.update_receiving_status(False)

    def toggle_recording(self):
        self.is_recording = not self.is_recording
        if self.is_recording:
            self.send_button.setText("Recording...")
            self.send_button.setStyleSheet("background-color: red; color: white; font-size: 16px; height: 50px;")
            self.status_label.setText("Recording...")
            asyncio.run_coroutine_threadsafe(self.start_recording(), self.loop)
        else:
            self.send_button.setText("Press to Talk")
            self.send_button.setStyleSheet("background-color: green; color: white; font-size: 16px; height: 50px;")
            self.status_label.setText("Idle")
            asyncio.run_coroutine_threadsafe(self.stop_recording(), self.loop)

    async def start_recording(self):
        try:
            await self.connect()
        except Exception as e:
            self.log(f"Connection failed: {e}")
            return
        response = await self.send_control_message("start")
        if response == "start_ack":
            # Start recording audio using sounddevice.
            self.recording_stream = sd.InputStream(
                callback=self.audio_callback,
                channels=1,
                samplerate=44100,
                dtype=np.int16
            )
            self.recording_stream.start()
            self.log("Started recording")
            await self.receive_audio()
        else:
            self.log("Failed to set sender")

    async def stop_recording(self):
        if hasattr(self, "recording_stream"):
            self.recording_stream.stop()
        self.log("Stopped recording")
        try:
            await self.send_control_message("stop")
        except Exception as e:
            self.log(f"Error sending stop message: {e}")

    def audio_callback(self, indata, frames, time, status):
        if self.is_recording:
            audio_data = indata.tobytes()
            self.log(f"Captured audio data: {len(audio_data)} bytes")
            asyncio.run_coroutine_threadsafe(self.send_audio(audio_data), self.loop)

    def update_receiving_status(self, is_receiving):
        self.is_receiving = is_receiving
        if self.is_receiving:
            self.status_label.setText("Receiving Audio...")
            self.status_label.setStyleSheet("color: blue; font-size: 16px;")
        else:
            self.status_label.setText("Idle")
            self.status_label.setStyleSheet("color: black; font-size: 16px;")

if __name__ == "__main__":
    loop_thread = EventLoopThread()
    loop_thread.start()

    app = QApplication(sys.argv)
    while loop_thread.loop is None:
        pass

    client = WebSocketClient(loop_thread)
    client.show()

    exit_code = app.exec_()
    loop_thread.stop_loop()
    loop_thread.quit()
    loop_thread.wait()
    sys.exit(exit_code)