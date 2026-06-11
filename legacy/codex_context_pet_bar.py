#!/usr/bin/env python3
import glob
import json
import os
import tkinter as tk
from pathlib import Path


CODEX_HOME = Path.home() / ".codex"
REFRESH_MS = 3000


def compact_number(value):
    value = int(value or 0)
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.0f}K"
    return str(value)


def load_thread_names():
    names = {}
    index = CODEX_HOME / "session_index.jsonl"
    if not index.exists():
        return names
    try:
        with index.open("r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("id"):
                    names[item["id"]] = item.get("thread_name") or "Codex thread"
    except OSError:
        pass
    return names


def latest_rollout_path():
    candidates = glob.glob(str(CODEX_HOME / "sessions" / "**" / "rollout-*.jsonl"), recursive=True)
    if not candidates:
        candidates = glob.glob(str(CODEX_HOME / "archived_sessions" / "rollout-*.jsonl"))
    if not candidates:
        return None
    return Path(max(candidates, key=lambda path: os.path.getmtime(path)))


def read_context_state(path):
    names = load_thread_names()
    state = {
        "thread_id": "",
        "thread_name": "No active Codex thread",
        "window": 0,
        "context_tokens": 0,
        "total_tokens": 0,
        "last_tokens": 0,
        "level": 0,
        "mtime": 0,
    }
    if not path or not path.exists():
        return state

    state["mtime"] = os.path.getmtime(path)
    explicit_compactions = 0
    previous_context_tokens = None
    inferred_compactions = 0

    try:
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue

                payload = item.get("payload") or {}
                item_type = item.get("type")
                payload_type = payload.get("type")

                if item_type == "session_meta":
                    thread_id = payload.get("id") or ""
                    state["thread_id"] = thread_id
                    state["thread_name"] = names.get(thread_id) or payload.get("thread_name") or "Codex thread"

                if payload_type == "task_started":
                    state["window"] = payload.get("model_context_window") or state["window"]

                if "compact" in str(payload_type or "").lower():
                    explicit_compactions += 1

                if item_type == "response_item" and "compact" in str(payload_type or "").lower():
                    explicit_compactions += 1

                if payload_type == "token_count":
                    info = payload.get("info") or {}
                    last = info.get("last_token_usage") or {}
                    total = info.get("total_token_usage") or {}
                    state["window"] = info.get("model_context_window") or state["window"]
                    context_tokens = last.get("input_tokens") or last.get("total_tokens") or 0
                    state["context_tokens"] = context_tokens
                    state["last_tokens"] = last.get("total_tokens") or context_tokens
                    state["total_tokens"] = total.get("total_tokens") or state["total_tokens"]

                    if previous_context_tokens and context_tokens:
                        if context_tokens < previous_context_tokens * 0.45 and previous_context_tokens > 60_000:
                            inferred_compactions += 1
                    previous_context_tokens = context_tokens or previous_context_tokens
    except OSError:
        pass

    state["level"] = max(explicit_compactions, inferred_compactions)
    if not state["thread_id"]:
        state["thread_id"] = path.stem.split("-")[-1]
    if state["thread_name"] == "No active Codex thread":
        state["thread_name"] = names.get(state["thread_id"], "Codex thread")
    return state


class ContextPetBar:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Codex Context Pet Bar")
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", 0.96)
        self.root.configure(bg="#171717")
        self.root.resizable(False, False)

        self.drag_x = 0
        self.drag_y = 0

        self.frame = tk.Frame(self.root, bg="#171717", padx=14, pady=10)
        self.frame.pack(fill="both", expand=True)

        self.title = tk.Label(
            self.frame,
            text="Codex Context",
            fg="#f5f5f5",
            bg="#171717",
            font=("Menlo", 12, "bold"),
            anchor="w",
        )
        self.title.pack(fill="x")

        self.canvas = tk.Canvas(self.frame, width=288, height=14, bg="#2b2b2b", bd=0, highlightthickness=0)
        self.canvas.pack(pady=(8, 6))

        self.stats = tk.Label(
            self.frame,
            text="LV 0  Context 0%  XP 0",
            fg="#e7e7e7",
            bg="#171717",
            font=("Menlo", 11),
            anchor="w",
        )
        self.stats.pack(fill="x")

        self.hint = tk.Label(
            self.frame,
            text="Move this near your pet · Esc to quit",
            fg="#9ca3af",
            bg="#171717",
            font=("Menlo", 9),
            anchor="w",
        )
        self.hint.pack(fill="x", pady=(4, 0))

        for widget in (self.root, self.frame, self.title, self.canvas, self.stats, self.hint):
            widget.bind("<ButtonPress-1>", self.start_drag)
            widget.bind("<B1-Motion>", self.drag)
        self.root.bind("<Escape>", lambda _event: self.root.destroy())
        self.root.bind("<ButtonPress-3>", lambda _event: self.root.destroy())
        self.root.after(100, self.place_window)
        self.root.after(300, self.keep_visible)

    def place_window(self):
        self.root.update_idletasks()
        width = max(self.root.winfo_reqwidth(), 340)
        height = max(self.root.winfo_reqheight(), 112)
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        x = max(20, screen_width - width - 70)
        y = max(40, screen_height - height - 190)
        self.root.geometry(f"{width}x{height}+{x}+{y}")
        self.root.lift()
        self.root.focus_force()

    def keep_visible(self):
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.root.after(5000, self.keep_visible)

    def start_drag(self, event):
        self.drag_x = event.x_root - self.root.winfo_x()
        self.drag_y = event.y_root - self.root.winfo_y()

    def drag(self, event):
        self.root.geometry(f"+{event.x_root - self.drag_x}+{event.y_root - self.drag_y}")

    def update_bar(self):
        state = read_context_state(latest_rollout_path())
        window = state["window"] or 1
        used = state["context_tokens"]
        pct = max(0, min(100, round(used / window * 100)))

        if pct >= 85:
            color = "#ef4444"
            mood = "Open new?"
        elif pct >= 65:
            color = "#f59e0b"
            mood = "Near compact"
        else:
            color = "#22c55e"
            mood = "Healthy"

        width = 288
        fill = int(width * pct / 100)
        self.canvas.delete("all")
        self.canvas.create_rectangle(0, 0, width, 12, fill="#2b2b2b", outline="")
        self.canvas.create_rectangle(0, 0, fill, 12, fill=color, outline="")

        title = state["thread_name"]
        if len(title) > 27:
            title = title[:26] + "…"
        self.title.configure(text=title)
        self.stats.configure(
            text=f"LV {state['level']}  Context {pct}%  XP {compact_number(state['total_tokens'])}"
        )
        self.hint.configure(text=f"{mood} · {compact_number(used)}/{compact_number(window)} · Esc or right-click to quit")
        self.root.after(REFRESH_MS, self.update_bar)

    def run(self):
        self.update_bar()
        self.root.mainloop()


if __name__ == "__main__":
    ContextPetBar().run()
