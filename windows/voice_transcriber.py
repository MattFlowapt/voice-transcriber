"""Voice Transcriber for Windows: push-to-talk dictation into any app.

Ctrl+Alt+Space starts recording; press it again and your words are transcribed by
OpenAI and pasted where your cursor is. Esc throws the recording away.
Ctrl+Alt+N while recording also keeps the take as a note; while idle it opens your notes.
The tray icon (bottom-right, maybe under the ^ arrow) has Notes, Settings and Quit.

Config: %APPDATA%\\voice-transcriber\\config.json    (same format as the Mac app)
Log:    %LOCALAPPDATA%\\VoiceTranscriber\\voice-transcriber.log
Check the whole setup:   python voice_transcriber.py --check
"""
import ctypes
import io
import json
import math
import os
import queue
import re
import sys
import threading
import time
import uuid
import wave
import urllib.error
import urllib.request
from datetime import datetime, timezone

import tkinter as tk
from tkinter import ttk

IS_WIN = sys.platform == "win32"
APPDATA = os.environ.get("APPDATA") or os.path.expanduser("~")
LOCALAPPDATA = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
CONFIG_DIR = os.path.join(APPDATA, "voice-transcriber")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
NOTES_PATH = os.path.join(CONFIG_DIR, "notes.json")
LOG_DIR = os.path.join(LOCALAPPDATA, "VoiceTranscriber")
LOG_PATH = os.path.join(LOG_DIR, "voice-transcriber.log")
RATE = 16000  # what gets uploaded: 16 kHz mono 16-bit WAV (5 min is ~9.6 MB, under OpenAI's 25 MB)

MODELS = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
LENGTHS = [(60, "1 min"), (120, "2 min"), (300, "5 min"), (600, "10 min"), (900, "15 min")]
DEFAULTS = {
    "openaiKey": "",
    "model": "gpt-4o-transcribe",
    "language": "",
    "autoPaste": True,
    "maxSeconds": 300,
    "vocabulary": ["Claude", "ChatGPT", "OpenAI"],
    "replacements": {"Chat GPT": "ChatGPT"},
    "hotkey": "ctrl+alt+space",
    "noteHotkey": "ctrl+alt+n",
    "microphone": "",  # empty = the Windows default input device
}

# Palette, shared by every window.
BG = "#141414"
PANEL = "#1d1d1d"
LINE = "#2a2a2a"
TEXT = "#ececec"
DIM = "#8c8c8c"
FAINT = "#5c5c5c"
RED = "#ff453a"
AMBER = "#ffcc52"
GREEN = "#32d74b"
BLUE = "#0a84ff"
ORANGE = "#ff9f0a"
UI = "Segoe UI" if IS_WIN else "Helvetica"


# ---------------------------------------------------------------- basics

def log(msg):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}\n")
    except OSError:
        pass


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        log(f"config unreadable, using defaults: {e}")
    return cfg


def save_config(cfg):
    """Atomic write. Keys this app doesn't know about are kept."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CONFIG_PATH)


def apply_replacements(text, cfg):
    """Hard spelling fixes: whole words, any case, e.g. "Chat GPT" -> "ChatGPT"."""
    for wrong, right in (cfg.get("replacements") or {}).items():
        if wrong:
            text = re.sub(r"\b" + re.escape(wrong) + r"\b", lambda m, r=right: r, text, flags=re.IGNORECASE)
    return text


def is_prompt_echo(text, cfg):
    """On a silent take the model tends to return the vocabulary hint itself."""
    vocab = cfg.get("vocabulary") or []
    if len(vocab) < 3:
        return False
    norm = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
    t = norm(text)
    return t == norm(" ".join(vocab)) or norm(" ".join(vocab[:4])) in t


def multipart(fields, wav_bytes):
    boundary = "vt-" + uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                 f"Content-Type: audio/wav\r\n\r\n".encode() + wav_bytes + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def transcribe(wav_bytes, cfg):
    """Returns (True, text) or (False, a short human-readable error)."""
    fields = {"model": cfg.get("model") or "gpt-4o-transcribe"}
    vocab = cfg.get("vocabulary") or []
    if vocab:
        fields["prompt"] = ", ".join(vocab)
    if (cfg.get("language") or "").strip():
        fields["language"] = cfg["language"].strip()
    body, ctype = multipart(fields, wav_bytes)
    req = urllib.request.Request("https://api.openai.com/v1/audio/transcriptions", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {cfg.get('openaiKey', '').strip()}",
                                          "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return True, (json.loads(r.read().decode("utf-8")).get("text") or "").strip()
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = json.loads(e.read().decode("utf-8")).get("error", {}).get("message", "")
        except Exception:
            pass
        log(f"OpenAI HTTP {e.code}: {detail}")
        if e.code == 401:
            return False, "OpenAI key rejected (401). Check it in Settings"
        if e.code == 429:
            return False, "OpenAI: no credit left or rate limited (429)"
        return False, f"OpenAI error {e.code}"
    except Exception as e:
        log(f"transcription request failed: {e}")
        return False, "Couldn't reach OpenAI. Check the internet"


# ---------------------------------------------------------------- Windows helpers

if IS_WIN:
    user32 = ctypes.windll.user32
    user32.GetForegroundWindow.restype = ctypes.c_void_p
    user32.GetParent.restype = ctypes.c_void_p
    user32.GetParent.argtypes = [ctypes.c_void_p]
    user32.GetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int]
    user32.SetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_long]
    user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
    user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]


def foreground_window():
    return user32.GetForegroundWindow() if IS_WIN else None


def set_windows_clipboard(text):
    """Puts the text on the clipboard directly. (Tk's own clipboard on Windows only
    hands the data over later, when the target app asks during the paste.)"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    u32 = ctypes.WinDLL("user32", use_last_error=True)
    k32.GlobalAlloc.restype = ctypes.c_void_p
    k32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    k32.GlobalLock.restype = ctypes.c_void_p
    k32.GlobalLock.argtypes = [ctypes.c_void_p]
    k32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    u32.SetClipboardData.restype = ctypes.c_void_p
    u32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    data = text.encode("utf-16-le") + b"\x00\x00"
    for _ in range(10):  # another app may hold the clipboard for a moment
        if u32.OpenClipboard(None):
            break
        time.sleep(0.03)
    else:
        raise OSError("clipboard is busy")
    try:
        u32.EmptyClipboard()
        h = k32.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        ptr = k32.GlobalLock(h)
        ctypes.memmove(ptr, data, len(data))
        k32.GlobalUnlock(h)
        if not u32.SetClipboardData(13, h):  # CF_UNICODETEXT; the system owns h now
            raise OSError("SetClipboardData failed")
    finally:
        u32.CloseClipboard()


def window_title(hwnd):
    if not (IS_WIN and hwnd):
        return ""
    buf = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, buf, 256)
    title = buf.value
    # "Document - Word" → "Word": the app name is usually the last part.
    return title.rsplit(" - ", 1)[-1].strip() if title else ""


def hwnd_of(win):
    return user32.GetParent(win.winfo_id()) if IS_WIN else None


def make_noactivate(win):
    """The pill must never take focus, or the paste would land in it."""
    if IS_WIN:
        hwnd = hwnd_of(win)
        ex = user32.GetWindowLongW(hwnd, -20)  # GWL_EXSTYLE
        user32.SetWindowLongW(hwnd, -20, ex | 0x08000000 | 0x00000080)  # NOACTIVATE | TOOLWINDOW


def dark_titlebar(win):
    if IS_WIN:
        try:
            val = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(ctypes.c_void_p(hwnd_of(win)), 20,
                                                       ctypes.byref(val), ctypes.sizeof(val))
        except Exception:
            pass


def single_instance():
    """False if another copy is already running."""
    if not IS_WIN:
        return True
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    global _mutex  # keep the handle for the life of the process
    _mutex = kernel32.CreateMutexW(None, False, "VoiceTranscriber.SingleInstance")
    return ctypes.get_last_error() != 183  # ERROR_ALREADY_EXISTS


# ---------------------------------------------------------------- audio

def input_devices():
    """(index, name) of input devices on the same host API as the default input,
    so each mic is listed once rather than once per Windows audio API."""
    import sounddevice as sd
    try:
        default_api = sd.query_devices(kind="input")["hostapi"]
    except Exception:
        default_api = None
    out, seen = [], set()
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and (default_api is None or d["hostapi"] == default_api):
            if d["name"] not in seen:
                seen.add(d["name"])
                out.append((i, d["name"]))
    return out


def pick_device(wanted):
    """(device index or None for the default, display name)."""
    import sounddevice as sd
    if wanted:
        for i, name in input_devices():
            if name == wanted:
                return i, name
    try:
        return None, sd.query_devices(kind="input")["name"]
    except Exception:
        return None, "No microphone"


class Recorder:
    def __init__(self):
        self.stream = None
        self.frames = []
        self.rate = RATE
        self.level = 0.0
        self.lock = threading.Lock()

    def start(self, device):
        import numpy as np
        import sounddevice as sd
        self.frames, self.level = [], 0.0

        def callback(indata, frames, t, status):
            data = indata[:, 0].copy()
            with self.lock:
                self.frames.append(data)
            rms = float(np.sqrt(np.mean((data.astype(np.float32) / 32768.0) ** 2))) + 1e-9
            self.level = max(0.0, min(1.0, (20 * math.log10(rms) + 50) / 40))

        try:
            self.rate = RATE
            self.stream = sd.InputStream(samplerate=RATE, channels=1, dtype="int16", device=device, callback=callback)
        except Exception:
            # Some devices refuse 16 kHz; record at their own rate and resample on stop.
            info = sd.query_devices(device, "input") if device is not None else sd.query_devices(kind="input")
            self.rate = int(info["default_samplerate"])
            self.stream = sd.InputStream(samplerate=self.rate, channels=1, dtype="int16", device=device, callback=callback)
        self.stream.start()

    def stop(self):
        """Returns (wav_bytes, seconds). Safe to call when not recording."""
        import numpy as np
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
            self.stream = None
        with self.lock:
            audio = np.concatenate(self.frames) if self.frames else np.zeros(0, dtype=np.int16)
            self.frames = []
        if self.rate != RATE and len(audio):
            n = int(len(audio) * RATE / self.rate)
            audio = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.int16)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(audio.tobytes())
        return buf.getvalue(), len(audio) / RATE


# ---------------------------------------------------------------- notes

class NotesStore:
    """Same notes.json format as the Mac app: newest first."""

    def load(self):
        try:
            with open(NOTES_PATH, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return []

    def add(self, text, app_name):
        notes = self.load()
        notes.insert(0, {"id": uuid.uuid4().hex, "text": text,
                         "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "app": app_name or None})
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = NOTES_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(notes, f, indent=2, ensure_ascii=False)
        os.replace(tmp, NOTES_PATH)


def note_meta(note):
    try:
        when = datetime.strptime(note["createdAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone()
    except (KeyError, ValueError):
        return note.get("app") or ""
    today = datetime.now().astimezone().date()
    if when.date() == today:
        day = "Today"
    elif (today - when.date()).days == 1:
        day = "Yesterday"
    else:
        day = when.strftime("%a %d %b" if when.year == today.year else "%d %b %Y")
    meta = f"{day} {when:%H:%M}"
    return meta + (f"  ·  {note['app']}" if note.get("app") else "")


# ---------------------------------------------------------------- the pill

def rounded_rect(c, x1, y1, x2, y2, r, **kw):
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
           x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return c.create_polygon(pts, smooth=True, **kw)


class Pill:
    """Black pill at the top-centre of the screen. Always mapped, never focusable;
    hidden by moving it off-screen, so showing it can't steal focus."""
    KEY = "#010203"  # transparent colour, so the rounded corners show the desktop

    def __init__(self, app):
        self.app = app
        s = app.s
        self.w, self.h = s(330), s(40)
        self.win = tk.Toplevel(app.root)
        self.win.overrideredirect(True)
        self.win.attributes("-topmost", True)
        self.win.configure(bg=self.KEY)
        if IS_WIN:
            self.win.attributes("-transparentcolor", self.KEY)
        self.c = tk.Canvas(self.win, width=self.w, height=self.h, bg=self.KEY, highlightthickness=0)
        self.c.pack()
        self.hide_job = None
        self.hide()
        self.win.update_idletasks()
        make_noactivate(self.win)

    def _place(self):
        x = (self.win.winfo_screenwidth() - self.w) // 2
        self.win.geometry(f"{self.w}x{self.h}+{x}+{self.app.s(10)}")
        self.win.lift()

    def _base(self):
        s = self.app.s
        self.c.delete("all")
        rounded_rect(self.c, 1, 1, self.w - 1, self.h - 1, s(18), fill="#0b0b0b", outline="#262626")

    def _show(self, auto_hide=None):
        if self.hide_job:
            self.app.root.after_cancel(self.hide_job)
            self.hide_job = None
        self._place()
        if auto_hide:
            self.hide_job = self.app.root.after(int(auto_hide * 1000), self.hide)

    def hide(self):
        self.hide_job = None
        if IS_WIN:  # parked off-screen rather than withdrawn: re-showing can't take focus
            self.win.geometry(f"{self.w}x{self.h}+-5000+-5000")
        else:
            self.win.withdraw()

    def recording(self, elapsed, level, mic, note):
        s = self.app.s
        self._base()
        colour = AMBER if note else RED
        r = s(4) + level * s(4)
        cx, cy = s(22), self.h // 2
        self.c.create_oval(cx - r, cy - r, cx + r, cy + r, fill=colour, outline="")
        self.c.create_text(s(38), cy, anchor="w", fill=TEXT, font=(UI, 12, "bold"),
                           text=f"{int(elapsed) // 60}:{int(elapsed) % 60:02d}")
        x = s(84)
        if note:
            self.c.create_text(x, cy, anchor="w", fill=AMBER, font=(UI, 9, "bold"), text="NOTE")
        name = mic if len(mic) <= 30 else mic[:29] + "…"
        self.c.create_text(self.w - s(16), cy, anchor="e", fill=DIM, font=(UI, 9), text=name)
        self._show()

    def message(self, dot, text, sub="", auto_hide=None):
        s = self.app.s
        self._base()
        cy = self.h // 2
        self.c.create_oval(s(18), cy - s(4), s(26), cy + s(4), fill=dot, outline="")
        tid = self.c.create_text(s(36), cy, anchor="w", fill=TEXT, font=(UI, 11, "bold"), text=text)
        if sub:
            x2 = self.c.bbox(tid)[2]
            self.c.create_text(x2 + s(8), cy, anchor="w", fill=DIM, font=(UI, 9), text=sub)
        self._show(auto_hide)

    def transcribing(self):
        self.message(BLUE, "Transcribing…")

    def done(self, text, sub=""):
        self.message(GREEN, text, sub, auto_hide=1.6)

    def error(self, text):
        self.message(ORANGE, text, auto_hide=3.5)


# ---------------------------------------------------------------- shared window chrome

def styled_toplevel(app, title, width):
    win = tk.Toplevel(app.root)
    win.withdraw()
    win.title(title)
    win.configure(bg=BG)
    win.resizable(False, False)
    win.attributes("-topmost", True)
    win.minsize(app.s(width), 10)
    win.protocol("WM_DELETE_WINDOW", win.withdraw)
    win.bind("<Escape>", lambda e: win.withdraw())
    return win


def center_top(app, win):
    win.update_idletasks()
    w = win.winfo_reqwidth()
    x = (win.winfo_screenwidth() - w) // 2
    y = max(app.s(40), int(win.winfo_screenheight() * 0.14))
    win.geometry(f"+{x}+{y}")


def label(parent, text, size=10, weight="normal", fg=TEXT, bg=BG, **kw):
    return tk.Label(parent, text=text, fg=fg, bg=bg, font=(UI, size, weight), **kw)


def link(parent, text, command, fg=DIM, bg=BG, size=9):
    l = label(parent, text, size, "bold", fg=fg, bg=bg, cursor="hand2")
    l.bind("<Button-1>", lambda e: command())
    l.bind("<Enter>", lambda e: l.configure(fg=TEXT))
    l.bind("<Leave>", lambda e: l.configure(fg=fg))
    return l


class Toggle(tk.Canvas):
    """Monochrome capsule switch, matching the Mac app."""

    def __init__(self, parent, app, on, command):
        self.app, self.on, self.command = app, on, command
        super().__init__(parent, width=app.s(34), height=app.s(20), bg=parent["bg"], highlightthickness=0,
                         cursor="hand2")
        self.bind("<Button-1>", self._click)
        self.draw()

    def draw(self):
        s = self.app.s
        self.delete("all")
        w, h = s(34), s(20)
        rounded_rect(self, 1, 1, w - 1, h - 1, h // 2, fill="#e6e6e6" if self.on else "#333333", outline="")
        d = h - s(6)
        x = w - d - s(3) if self.on else s(3)
        self.create_oval(x, s(3), x + d, s(3) + d, fill="#111111" if self.on else "#b0b0b0", outline="")

    def _click(self, _):
        self.on = not self.on
        self.draw()
        self.command(self.on)


class PlaceholderEntry(tk.Entry):
    def __init__(self, parent, placeholder, width=18, show=None, justify="left"):
        super().__init__(parent, width=width, bg=PANEL, fg=TEXT, insertbackground=TEXT, relief="flat",
                         font=(UI, 10), justify=justify, highlightthickness=1, highlightbackground=LINE,
                         highlightcolor="#4a4a4a")
        self.placeholder, self.real_show = placeholder, show or ""
        self.bind("<FocusIn>", self._in)
        self.bind("<FocusOut>", self._out)
        self._out(None)

    def _in(self, _):
        if self.cget("fg") == FAINT:
            self.delete(0, "end")
            self.configure(fg=TEXT, show=self.real_show)

    def _out(self, _):
        if not self.get():
            self.configure(fg=FAINT, show="")
            self.insert(0, self.placeholder)

    def value(self):
        return "" if self.cget("fg") == FAINT else self.get().strip()

    def set(self, text):
        self.delete(0, "end")
        if text:
            self.configure(fg=TEXT, show=self.real_show)
            self.insert(0, text)
        else:
            self._out(None)


# ---------------------------------------------------------------- notes window

class NotesWindow:
    def __init__(self, app):
        self.app = app
        self.win = None

    def visible(self):
        return bool(self.win and self.win.winfo_viewable())

    def toggle(self):
        self.close() if self.visible() else self.open()

    def close(self):
        if self.win:
            self.win.withdraw()

    def open(self):
        app, s = self.app, self.app.s
        if self.win is None:
            self.win = styled_toplevel(app, "Notes", 460)
        win = self.win
        for child in win.winfo_children():
            child.destroy()
        notes = app.notes.load()
        head = tk.Frame(win, bg=BG)
        head.pack(fill="x", padx=s(20), pady=(s(16), s(10)))
        label(head, "Notes", 15, "bold").pack(side="left")
        label(head, f"  {len(notes)}", 10, fg=DIM).pack(side="left", pady=(s(4), 0))
        label(head, app.cfg.get("noteHotkey", "ctrl+alt+n").title(), 8, "bold", fg=DIM, bg=PANEL,
              padx=s(6), pady=s(2)).pack(side="right")
        tk.Frame(win, bg=LINE, height=1).pack(fill="x")

        body = tk.Frame(win, bg=BG)
        body.pack(fill="both", expand=True, padx=s(10), pady=s(8))
        if not notes:
            label(body, "No notes yet", 11, "bold", fg=DIM).pack(pady=(s(24), s(4)))
            label(body, "While recording, press Ctrl+Alt+N to keep the dictation as a note.", 9,
                  fg=FAINT).pack(pady=(0, s(24)))
        else:
            canvas = tk.Canvas(body, bg=BG, highlightthickness=0, width=s(440),
                               height=min(s(460), s(70) * len(notes)))
            inner = tk.Frame(canvas, bg=BG)
            canvas.create_window((0, 0), window=inner, anchor="nw", width=s(440))
            inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
            canvas.pack(fill="both", expand=True)
            canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(int(-e.delta / 120), "units")
                            if self.visible() else None)
            for n in notes:
                self._row(inner, n)
        label(win, "Click a note to copy  ·  Esc to close", 8, fg=FAINT).pack(pady=(s(2), s(12)))
        dark_titlebar(win)
        center_top(app, win)
        win.deiconify()
        win.lift()
        win.focus_force()

    def _row(self, parent, note):
        s = self.app.s
        row = tk.Frame(parent, bg=BG, cursor="hand2")
        row.pack(fill="x", pady=1)
        meta = label(row, note_meta(note), 8, fg=FAINT)
        meta.pack(anchor="w", padx=s(12), pady=(s(8), 0))
        text = label(row, note.get("text", ""), 10, justify="left", wraplength=s(400), anchor="w")
        text.pack(anchor="w", fill="x", padx=s(12), pady=(s(2), s(9)))
        widgets = (row, meta, text)

        def hover(on):
            for w in widgets:
                w.configure(bg=PANEL if on else BG)

        def copy(_):
            self.app.set_clipboard(note.get("text", ""))
            meta.configure(text="Copied ✓", fg=GREEN)
            self.app.root.after(1200, lambda: meta.configure(text=note_meta(note), fg=FAINT))

        for w in widgets:
            w.bind("<Enter>", lambda e: hover(True))
            w.bind("<Leave>", lambda e: hover(False))
            w.bind("<Button-1>", copy)


# ---------------------------------------------------------------- settings window

class SettingsWindow:
    """Two tabs, no Save button: every change is written straight away."""

    def __init__(self, app):
        self.app = app
        self.win = None
        self.tab = 0
        self.editing_key = False
        self.status_job = None

    def open(self, tab=None):
        if tab is not None:
            self.tab = tab
        if self.win is None:
            self.win = styled_toplevel(self.app, "Voice Transcriber Settings", 480)
            self.win.bind("<Escape>", lambda e: self.close())
            self.win.protocol("WM_DELETE_WINDOW", self.close)
        self.editing_key = False
        self.render()
        dark_titlebar(self.win)
        center_top(self.app, self.win)
        self.win.deiconify()
        self.win.lift()
        self.win.focus_force()

    def close(self):
        if self.win:
            self.save_names()
            self.win.withdraw()

    def render(self):
        s, win = self.app.s, self.win
        for child in win.winfo_children():
            child.destroy()
        head = tk.Frame(win, bg=BG)
        head.pack(fill="x", padx=s(20), pady=(s(16), s(12)))
        label(head, "Settings", 15, "bold").pack(side="left")
        tabs = tk.Frame(head, bg=PANEL, padx=s(2), pady=s(2))
        tabs.pack(side="right")
        for i, name in enumerate(["Words", "Recording"]):
            active = i == self.tab
            t = label(tabs, name, 9, "bold", fg=TEXT if active else DIM, bg="#333333" if active else PANEL,
                      padx=s(12), pady=s(3), cursor="hand2")
            t.pack(side="left")
            t.bind("<Button-1>", lambda e, i=i: self.switch(i))
        tk.Frame(win, bg=LINE, height=1).pack(fill="x")
        page = tk.Frame(win, bg=BG)
        page.pack(fill="both", padx=s(20), pady=(s(12), 0))
        (self.words_page if self.tab == 0 else self.recording_page)(page)
        self.status = label(win, "", 8, fg=FAINT)
        self.status.pack(pady=(s(12), s(12)))
        self.set_status(None)

    def switch(self, i):
        self.save_names()
        self.tab = i
        self.render()

    def set_status(self, text, error=False):
        if self.status_job:
            self.app.root.after_cancel(self.status_job)
            self.status_job = None
        if text is None:
            self.status.configure(text="Changes save automatically  ·  Esc to close", fg=FAINT)
        else:
            self.status.configure(text=text, fg=ORANGE if error else GREEN)
            if not error:
                self.status_job = self.app.root.after(1400, lambda: self.set_status(None))

    def commit(self):
        try:
            self.app.apply_config(self.app.cfg)
            self.set_status("Saved ✓")
        except Exception as e:
            log(f"settings save failed: {e}")
            self.set_status(f"Couldn't save: {e}", error=True)

    def section(self, parent, title, hint):
        s = self.app.s
        row = tk.Frame(parent, bg=BG)
        row.pack(fill="x", pady=(s(6), s(4)))
        label(row, title.upper(), 8, "bold", fg=DIM).pack(side="left")
        label(row, hint, 8, fg=FAINT).pack(side="right")

    # Words

    def words_page(self, page):
        app, s = self.app, self.app.s
        self.section(page, "Spelling fixes", "heard → written")
        fixes = app.cfg.get("replacements") or {}
        for wrong in sorted(fixes, key=str.lower):
            row = tk.Frame(page, bg=BG)
            row.pack(fill="x", pady=1)
            label(row, wrong, 10, fg=DIM, width=18, anchor="w").pack(side="left", padx=(s(4), 0))
            label(row, "→", 9, fg=FAINT).pack(side="left", padx=s(6))
            label(row, fixes[wrong], 10, "bold").pack(side="left")
            link(row, "✕", lambda w=wrong: self.remove_fix(w)).pack(side="right", padx=s(6))
        add = tk.Frame(page, bg=BG)
        add.pack(fill="x", pady=(s(6), s(14)))
        self.heard = PlaceholderEntry(add, "Heard as", width=20)
        self.heard.pack(side="left", ipady=s(3))
        label(add, "→", 9, fg=FAINT).pack(side="left", padx=s(8))
        self.write_as = PlaceholderEntry(add, "Write as", width=20)
        self.write_as.pack(side="left", ipady=s(3))
        for e in (self.heard, self.write_as):
            e.bind("<Return>", lambda ev: self.add_fix())

        self.section(page, "Names", "helps it recognise them, separated by commas")
        self.names = tk.Text(page, height=5, width=52, wrap="word", bg=PANEL, fg=TEXT, insertbackground=TEXT,
                             relief="flat", font=(UI, 10), padx=s(8), pady=s(6), highlightthickness=1,
                             highlightbackground=LINE, highlightcolor="#4a4a4a")
        self.names.insert("1.0", ", ".join(app.cfg.get("vocabulary") or []))
        self.names.pack(fill="x")
        self.names.bind("<FocusOut>", lambda e: self.save_names())
        self.names_loaded = self.names.get("1.0", "end").strip()

    def add_fix(self):
        wrong, right = self.heard.value(), self.write_as.value()
        if not wrong:
            return
        if not right:
            self.write_as.focus_set()
            return
        fixes = dict(self.app.cfg.get("replacements") or {})
        for k in [k for k in fixes if k.lower() == wrong.lower()]:
            del fixes[k]
        fixes[wrong] = right
        self.app.cfg["replacements"] = fixes
        self.commit()
        self.render()
        self.heard.focus_set()

    def remove_fix(self, wrong):
        fixes = dict(self.app.cfg.get("replacements") or {})
        fixes.pop(wrong, None)
        self.app.cfg["replacements"] = fixes
        self.commit()
        self.render()

    def save_names(self):
        names_widget = getattr(self, "names", None)
        if self.tab != 0 or names_widget is None or not names_widget.winfo_exists():
            return
        raw = names_widget.get("1.0", "end").strip()
        if raw == self.names_loaded:
            return
        seen, names = set(), []
        for n in re.split(r"[,\n]", raw):
            n = n.strip()
            if n and n.lower() not in seen:
                seen.add(n.lower())
                names.append(n)
        self.app.cfg["vocabulary"] = names
        self.names_loaded = raw
        self.commit()

    # Recording

    def row(self, page, title, sub, first=False):
        s = self.app.s
        if not first:
            tk.Frame(page, bg=LINE, height=1).pack(fill="x")
        r = tk.Frame(page, bg=BG)
        r.pack(fill="x", pady=s(8))
        left = tk.Frame(r, bg=BG)
        left.pack(side="left")
        label(left, title, 10, "bold").pack(anchor="w")
        if sub:
            label(left, sub, 8, fg=DIM).pack(anchor="w")
        right = tk.Frame(r, bg=BG)
        right.pack(side="right")
        return right

    def combo(self, parent, values, current, on_pick, width=22):
        cb = ttk.Combobox(parent, values=values, state="readonly", width=width, style="Dark.TCombobox",
                          font=(UI, 10))
        if current in values:
            cb.set(current)
        cb.bind("<<ComboboxSelected>>", lambda e: on_pick(cb.get()))
        return cb

    def recording_page(self, page):
        app, cfg = self.app, self.app.cfg

        def setter(key, transform=lambda v: v):
            def apply(value):
                cfg[key] = transform(value)
                self.commit()
            return apply

        self.combo(self.row(page, "Model", None, first=True), MODELS, cfg.get("model"),
                   setter("model")).pack()

        lang = PlaceholderEntry(self.row(page, "Language", "Leave empty to detect it"), "Auto-detect",
                                width=14, justify="right")
        lang.set(cfg.get("language", ""))
        lang.pack(ipady=2)
        for ev in ("<Return>", "<FocusOut>"):
            lang.bind(ev, lambda e: (cfg.get("language", "") != lang.value()) and setter("language")(lang.value()),
                      add="+")

        Toggle(self.row(page, "Paste at the cursor", "Off: text is copied only"), app,
               bool(cfg.get("autoPaste", True)), setter("autoPaste")).pack()

        names = [n for _, n in LENGTHS]
        current = next((n for secs, n in LENGTHS if secs == int(cfg.get("maxSeconds", 300))), None)
        self.combo(self.row(page, "Longest take", None), names, current,
                   setter("maxSeconds", lambda n: dict((v, k) for k, v in LENGTHS)[n]), width=10).pack()

        try:
            mics = ["Windows default"] + [n for _, n in input_devices()]
        except Exception:
            mics = ["Windows default"]
        self.combo(self.row(page, "Microphone", None), mics, cfg.get("microphone") or "Windows default",
                   setter("microphone", lambda n: "" if n == "Windows default" else n), width=28).pack()

        hk = PlaceholderEntry(self.row(page, "Hotkey", "e.g. ctrl+alt+space"), "ctrl+alt+space", width=16,
                              justify="right")
        hk.set(cfg.get("hotkey", "ctrl+alt+space"))
        hk.pack(ipady=2)

        def save_hotkey(_):
            value = hk.value().lower().replace(" ", "")
            if value and value != cfg.get("hotkey"):
                old = cfg.get("hotkey")
                cfg["hotkey"] = value
                if not app.register_hotkeys():
                    cfg["hotkey"] = old
                    app.register_hotkeys()
                    self.set_status(f"“{value}” isn't a valid hotkey", error=True)
                    return
                self.commit()

        hk.bind("<Return>", save_hotkey)
        hk.bind("<FocusOut>", save_hotkey, add="+")

        right = self.row(page, "OpenAI key", None)
        key = (cfg.get("openaiKey") or "").strip()
        if self.editing_key:
            entry = PlaceholderEntry(right, "Paste a new key", width=26, show="•", justify="right")
            entry.pack(ipady=2)
            entry.focus_set()

            def save_key(_):
                if entry.value():
                    cfg["openaiKey"] = entry.value()
                    self.commit()
                self.editing_key = False
                self.render()

            entry.bind("<Return>", save_key)
            entry.bind("<Escape>", lambda e: (setattr(self, "editing_key", False), self.render(), "break")[-1])
        else:
            label(right, ("••••  " + key[-4:]) if key else "Not set", 9, fg=DIM).pack(side="left", padx=(0, 10))
            link(right, "Change" if key else "Add", self.start_key_edit).pack(side="left")

    def start_key_edit(self):
        self.editing_key = True
        self.render()


# ---------------------------------------------------------------- tray icon

def mic_image(recording):
    from PIL import Image, ImageDraw
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((2, 2, 62, 62), fill=(229, 72, 77, 255) if recording else (38, 38, 38, 255))
    white = (255, 255, 255, 255)
    d.rounded_rectangle((25, 12, 39, 38), radius=7, fill=white)
    d.arc((18, 22, 46, 46), start=0, end=180, fill=white, width=4)
    d.line((32, 46, 32, 52), fill=white, width=4)
    d.line((24, 53, 40, 53), fill=white, width=4)
    return img


class Tray:
    def __init__(self, app):
        import pystray
        self.app = app
        item = pystray.MenuItem
        menu = pystray.Menu(
            item(lambda i: "Mic: " + app.mic_label(), lambda icon, i: None, enabled=False),
            pystray.Menu.SEPARATOR,
            item("Notes", lambda icon, i: app.post(app.notes_window.toggle)),
            item("Settings…", lambda icon, i: app.post(app.settings.open), default=True),
            pystray.Menu.SEPARATOR,
            item("Quit", lambda icon, i: app.post(app.quit)),
        )
        self.icon = pystray.Icon("VoiceTranscriber", mic_image(False), "Voice Transcriber", menu)
        self.icon.run_detached()

    def set_recording(self, on):
        try:
            self.icon.icon = mic_image(on)
            self.icon.title = "Voice Transcriber: recording" if on else "Voice Transcriber"
        except Exception as e:
            log(f"tray update failed: {e}")

    def stop(self):
        try:
            self.icon.stop()
        except Exception:
            pass


# ---------------------------------------------------------------- the app

class App:
    def __init__(self):
        __import__("keyboard")  # fail early, with a clear log line, if it's missing
        self.cfg = load_config()
        self.root = tk.Tk()
        self.root.withdraw()
        self.scale = max(1.0, self.root.winfo_fpixels("1i") / 96.0)
        self.setup_style()
        self.q = queue.Queue()
        self.state = "idle"
        self.rec = Recorder()
        self.notes = NotesStore()
        self.is_note = False
        self.target = None
        self.started = 0.0
        self.last_toggle = 0.0
        self.mic_name = ""
        self.hotkeys = []
        self.esc = None
        self.pill = Pill(self)
        self.notes_window = NotesWindow(self)
        self.settings = SettingsWindow(self)
        self.tray = Tray(self)
        if not self.register_hotkeys():
            self.pill.error(f"Hotkey “{self.cfg.get('hotkey')}” didn't register")
        self.root.after(30, self.pump)
        log(f"VoiceTranscriber running (Windows) — model {self.cfg.get('model')}, "
            f"hotkey {self.cfg.get('hotkey')}, autoPaste {self.cfg.get('autoPaste')}")

    def s(self, px):
        return int(round(px * self.scale))

    def setup_style(self):
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("Dark.TCombobox", fieldbackground=PANEL, background=PANEL, foreground=TEXT,
                        arrowcolor=DIM, bordercolor=LINE, lightcolor=PANEL, darkcolor=PANEL, padding=4)
        style.map("Dark.TCombobox", fieldbackground=[("readonly", PANEL)], foreground=[("readonly", TEXT)],
                  selectbackground=[("readonly", PANEL)], selectforeground=[("readonly", TEXT)])
        self.root.option_add("*TCombobox*Listbox.background", PANEL)
        self.root.option_add("*TCombobox*Listbox.foreground", TEXT)
        self.root.option_add("*TCombobox*Listbox.selectBackground", "#333333")
        self.root.option_add("*TCombobox*Listbox.font", (UI, 10))

    # Everything that touches Tk runs on the Tk thread: hotkey and tray callbacks post here.
    def post(self, fn, *args):
        self.q.put((fn, args))

    def pump(self):
        while True:
            try:
                fn, args = self.q.get_nowait()
            except queue.Empty:
                break
            try:
                fn(*args)
            except Exception as e:
                log(f"error in {getattr(fn, '__name__', fn)}: {e!r}")
        self.root.after(30, self.pump)

    def register_hotkeys(self):
        import keyboard
        for h in self.hotkeys:
            try:
                keyboard.remove_hotkey(h)
            except Exception:
                pass
        self.hotkeys = []
        try:
            self.hotkeys.append(keyboard.add_hotkey(self.cfg.get("hotkey") or "ctrl+alt+space",
                                                    lambda: self.post(self.toggle), suppress=True))
            self.hotkeys.append(keyboard.add_hotkey(self.cfg.get("noteHotkey") or "ctrl+alt+n",
                                                    lambda: self.post(self.note_key), suppress=True))
        except Exception as e:
            log(f"hotkey registration failed: {e}")
            return False
        log(f"hotkey registered: {self.cfg.get('hotkey')} (note: {self.cfg.get('noteHotkey')})")
        return True

    def apply_config(self, cfg):
        save_config(cfg)
        self.cfg = cfg
        log(f"settings saved — model {cfg.get('model')}, {len(cfg.get('replacements') or {})} spelling fixes, "
            f"{len(cfg.get('vocabulary') or [])} names")

    def mic_label(self):
        try:
            return pick_device(self.cfg.get("microphone", ""))[1]
        except Exception:
            return "unavailable"

    def set_clipboard(self, text):
        if IS_WIN:
            try:
                set_windows_clipboard(text)
                return
            except Exception as e:
                log(f"clipboard via Win32 failed, using Tk: {e}")
        self.root.clipboard_clear()
        self.root.clipboard_append(text)

    # Recording flow

    def toggle(self):
        now = time.time()
        if now - self.last_toggle < 0.3:  # key repeat while the hotkey is held
            return
        self.last_toggle = now
        if self.state == "idle":
            self.start()
        elif self.state == "recording":
            self.stop()

    def note_key(self):
        if self.state == "recording":
            self.is_note = not self.is_note
        elif self.state == "idle":
            self.notes_window.toggle()

    def start(self):
        if not (self.cfg.get("openaiKey") or "").strip():
            self.pill.error("Add your OpenAI key in Settings")
            self.settings.open(tab=1)
            return
        self.notes_window.close()
        self.target = foreground_window()
        try:
            device, self.mic_name = pick_device(self.cfg.get("microphone", ""))
            self.rec.start(device)
        except Exception as e:
            log(f"record start failed: {e!r}")
            self.pill.error("Microphone failed. Is mic access allowed?")
            return
        import keyboard
        self.state, self.is_note, self.started = "recording", False, time.time()
        try:
            self.esc = keyboard.add_hotkey("esc", lambda: self.post(self.cancel), suppress=True)
        except Exception:
            self.esc = None
        self.tray.set_recording(True)
        log(f"recording started — mic: {self.mic_name}")
        self.tick()

    def tick(self):
        if self.state != "recording":
            return
        elapsed = time.time() - self.started
        if elapsed >= float(self.cfg.get("maxSeconds") or 300):
            self.stop()
            return
        self.pill.recording(elapsed, self.rec.level, self.mic_name, self.is_note)
        self.root.after(33, self.tick)

    def _release_esc(self):
        import keyboard
        if self.esc is not None:
            try:
                keyboard.remove_hotkey(self.esc)
            except Exception:
                pass
            self.esc = None

    def cancel(self):
        if self.state != "recording":
            return
        self._release_esc()
        self.rec.stop()
        self.state = "idle"
        self.tray.set_recording(False)
        self.pill.message(FAINT, "Cancelled", auto_hide=1.0)
        log("recording cancelled")

    def stop(self):
        self._release_esc()
        elapsed = time.time() - self.started
        wav, seconds = self.rec.stop()
        self.tray.set_recording(False)
        if elapsed < 0.4 or seconds < 0.3:
            self.state = "idle"
            self.pill.hide()
            return
        self.state = "transcribing"
        self.pill.transcribing()
        as_note, stop_pressed, cfg = self.is_note, time.time(), dict(self.cfg)
        log(f"recording stopped ({seconds:.1f} s captured, {len(wav) // 1024} KB) — transcribing")

        def work():
            result = transcribe(wav, cfg)
            self.post(self.finish, result, as_note, stop_pressed)

        threading.Thread(target=work, daemon=True).start()

    def finish(self, result, as_note, stop_pressed):
        self.state = "idle"
        ok, text = result
        if not ok:
            self.pill.error(text)
            return
        text = apply_replacements(text, self.cfg)
        if not text or is_prompt_echo(text, self.cfg):
            self.pill.error("No speech detected")
            log("empty transcript" if not text else "transcript was the vocabulary prompt echoed back — discarded")
            return
        app_name = window_title(self.target)
        pasted = self.deliver(text)
        if as_note:
            self.notes.add(text, app_name)
        ms = (time.time() - stop_pressed) * 1000
        self.pill.done(("Pasted" if pasted else "Copied") + (" · Noted" if as_note else "") + " ✓", f"{ms:.0f} ms")
        log(f"delivered {len(text)} chars in {ms:.0f} ms (pasted: {pasted} → {app_name or 'unknown app'}"
            f"{', saved as note' if as_note else ''})")

    def deliver(self, text):
        import keyboard
        self.set_clipboard(text)
        if not self.cfg.get("autoPaste", True):
            return False
        # Wait for the hotkey's modifiers to be let go, or Ctrl+V becomes Ctrl+Alt+V.
        deadline = time.time() + 1.5
        while time.time() < deadline and any(keyboard.is_pressed(k) for k in ("alt", "ctrl", "shift")):
            time.sleep(0.02)
        if IS_WIN and self.target and foreground_window() != self.target:
            user32.SetForegroundWindow(self.target)
            time.sleep(0.05)
        keyboard.send("ctrl+v")
        return True

    def quit(self):
        import keyboard
        log("quit from tray")
        try:
            keyboard.unhook_all()
        except Exception:
            pass
        self.tray.stop()
        self.root.destroy()
        os._exit(0)

    def run(self):
        self.root.mainloop()


# ---------------------------------------------------------------- --check

def check():
    """Checks every piece a real dictation needs and says what to fix."""
    problems = []
    print(f"Python {sys.version.split()[0]} on {sys.platform}")
    for mod in ("numpy", "sounddevice", "keyboard", "pystray", "PIL"):
        try:
            __import__(mod)
            print(f"  ok       {mod}")
        except Exception as e:
            print(f"  MISSING  {mod}: {e}")
            problems.append(f"install {mod}: python -m pip install -r requirements.txt")
    cfg = load_config()
    print(f"Config:  {CONFIG_PATH} ({'found' if os.path.exists(CONFIG_PATH) else 'NOT FOUND, using defaults'})")
    key = (cfg.get("openaiKey") or "").strip()
    if not key:
        problems.append("no OpenAI key: add it in Settings or config.json")
        print("  OpenAI key: not set")
    else:
        req = urllib.request.Request("https://api.openai.com/v1/models", headers={"Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                print(f"  OpenAI key: ••••{key[-4:]} accepted (HTTP {r.status})")
        except urllib.error.HTTPError as e:
            print(f"  OpenAI key: ••••{key[-4:]} REJECTED (HTTP {e.code})")
            problems.append(f"OpenAI key rejected (HTTP {e.code})")
        except Exception as e:
            print(f"  OpenAI: unreachable ({e})")
            problems.append("can't reach api.openai.com")
    wav = None
    try:
        devices = input_devices()
        print("Microphones:")
        for i, name in devices:
            print(f"  [{i}] {name}")
        device, name = pick_device(cfg.get("microphone", ""))
        print(f"Recording 3 seconds from: {name}. SAY SOMETHING NOW…")
        rec = Recorder()
        rec.start(device)
        peak = 0.0
        for _ in range(30):
            time.sleep(0.1)
            peak = max(peak, rec.level)
        wav, seconds = rec.stop()
        print(f"  captured {seconds:.1f} s, peak level {peak:.2f}")
        if seconds < 2:
            problems.append("the microphone delivered almost no audio")
        elif peak < 0.05:
            problems.append("the microphone recorded silence: check mic privacy settings / the chosen mic")
    except Exception as e:
        print(f"  microphone test FAILED: {e!r}")
        problems.append(f"microphone: {e}")
    if key and wav:
        ok, text = transcribe(wav, cfg)
        print(f"Transcription: {'ok' if ok else 'FAILED'}: {apply_replacements(text, cfg)!r}")
        if not ok:
            problems.append(text)
    startup = os.path.join(APPDATA, r"Microsoft\Windows\Start Menu\Programs\Startup", "Voice Transcriber.lnk")
    print(f"Starts at login: {'yes' if os.path.exists(startup) else 'no (run install.ps1)'}")
    print(f"Log: {LOG_PATH}")
    print()
    if problems:
        print("PROBLEMS FOUND:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("ALL GOOD. Press Ctrl+Alt+Space in any app, talk, press it again.")
    return 0


def main():
    if "--check" in sys.argv:
        sys.exit(check())
    if IS_WIN:
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)  # crisp text on scaled displays
        except Exception:
            pass
    if not single_instance():
        log("already running — exiting")
        return
    try:
        App().run()
    except Exception as e:
        log(f"fatal: {e!r}")
        raise


if __name__ == "__main__":
    main()
