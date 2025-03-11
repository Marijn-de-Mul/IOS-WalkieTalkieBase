import asyncio
import sys
import websockets
import sounddevice as sd
import numpy as np
import queue
from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QPushButton, QLabel, QTextEdit
from PyQt5.QtCore import Qt, QThread, pyqtSignal, QObject

BLOCKSIZE = 1024  # Adjust as needed

class EventLoopThread(QThread):
    """
    Thread that starts and runs an asyncio event loop forever.
    """
    def __init__(self):
        super().__init__()
        self.loop = None

    def run(self):
        # Create a new event loop for this thread and set it.
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
        # Use a unified connection (control endpoint) for both control and audio data.
        self.uri = "ws://walkietalkie.backend.marijndemul.nl/ws/control"
        self.is_recording = False
        self.is_receiving = False

        # Create a queue to store received audio buffers.
        self.audio_queue = queue.Queue()

        # Create an OutputStream for continuous playback.
        self.output_stream = sd.OutputStream(
            samplerate=44100, channels=1, dtype='int16',
            blocksize=BLOCKSIZE, callback=self.playback_callback
        )
        self.output_stream.start()

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

    def playback_callback(self, outdata, frames, time, status):
        # Fetch audio data from the queue; if none is available, output silence.
        try:
            data = self.audio_queue.get_nowait()
        except queue.Empty:
            outdata.fill(0)
        else:
            # Pad with zeros if the chunk is smaller than requested.
            if data.shape[0] < frames:
                pad_width = frames - data.shape[0]
                data = np.pad(data, ((0, pad_width), (0, 0)), mode='constant')
            outdata[:] = data[:frames]

    async def connect(self):
        self.websocket = await websockets.connect(self.uri)
        self.log("Connected to WebSocket (control endpoint)")

    async def send_control_message(self, message):
        self.log(f"Sending control message: {message}")
        await self.websocket.send(message)
        response = await self.websocket.recv()
        self.log(f"Control response: {response}")
        return response

    async def send_audio(self, audio_data):
        # Send audio data as binary.
        await self.websocket.send(audio_data)
        self.log(f"Sent audio data: {len(audio_data)} bytes")

    async def receive_audio(self):
        # Continuously listen for messages.
        while self.is_recording:
            try:
                message = await self.websocket.recv()
            except Exception as e:
                self.log(f"Error receiving audio: {e}")
                break
            if isinstance(message, bytes):
                if message:
                    self.log(f"Received {len(message)} bytes of audio data")
                    audio_data = np.frombuffer(message, dtype=np.int16).reshape(-1, 1)
                    self.audio_queue.put(audio_data)
                else:
                    self.log("Received empty audio data")
            elif isinstance(message, str):
                self.log(f"Received text message (control): {message}")
            await asyncio.sleep(0.01)

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
            self.recording_stream = sd.InputStream(
                callback=self.audio_callback,
                channels=1,
                samplerate=44100,
                dtype=np.int16,
                blocksize=BLOCKSIZE
            )
            self.recording_stream.start()
            self.log("Started recording")
            asyncio.ensure_future(self.receive_audio())
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