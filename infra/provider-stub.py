#!/usr/bin/env python3
"""A scripted OpenAI-compatible endpoint for infra/smoke.sh.

Scripted per agent, not per request: every agent shares one endpoint, so the counter is keyed
off the name the daemon puts in the system prompt. The final reply of any script carries what
the stub saw in that agent's transcript, so the smoke run can assert on one string that the
daemon really sent tool definitions, a bearer token, a base64 PNG and named senders.

Binds 127.0.0.1 only: check.sh asserts nothing but the web port listens off loopback.

    STUB_SCRIPT=tools|busy|talk|worker|memory|web STUB_SENDER=agent STUB_TO=agent \
    STUB_CMD_TIMEOUT_MS=30000 provider-stub.py PORT NONCE COMMAND

  tools  screenshot, run COMMAND, then report. The original script.
  busy   run COMMAND once, then report — a long COMMAND parks a turn so the run can post to a
         busy agent, or kill a daemon out from under the tool call.
  talk   STUB_SENDER writes to STUB_TO once; everyone else reports straight away.
  worker STUB_SENDER spawns a task worker once; the worker runs COMMAND and reports. A worker
         is told apart from a permanent agent by its system prompt, because its name is only
         decided when it is spawned.
  memory STUB_SENDER remembers the nonce once; everyone else reports straight away, which with
         no STUB_SENDER is everyone. The `memory`, `skills` and `schedules` fields of the report
         are the only way the smoke run can see what the daemon put in the system prompt.
  web    STUB_SENDER asks web_fetch for STUB_URL once. The only web step that can run offline is
         the refusal: a stub served from loopback is exactly what the guard exists to block.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, NONCE, COMMAND = int(sys.argv[1]), sys.argv[2], sys.argv[3]
TIMEOUT_MS = int(os.environ.get("STUB_CMD_TIMEOUT_MS", "30000"))
SCRIPT = os.environ.get("STUB_SCRIPT", "tools")
SENDER = os.environ.get("STUB_SENDER", "")
TO = os.environ.get("STUB_TO", "")
URL = os.environ.get("STUB_URL", "")
PNG_PREFIX = "data:image/png;base64,iVBORw0KGgo"

calls = {}


def tool_call(call_id, name, arguments):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }


def text_of(message):
    content = message.get("content")
    return content if isinstance(content, str) else ""


def agent_of(messages):
    """Who the daemon says this transcript belongs to. The system prompt is the only carrier."""
    system = text_of(messages[0]) if messages else ""
    found = re.search(r"You are (\S+),", system)
    return found.group(1) if found else ""


def is_worker(messages):
    """Whether this transcript belongs to a task worker. Its name is not known ahead of time,
    so the only handle is what the daemon tells it that it is."""
    return "task worker" in (text_of(messages[0]) if messages else "")


def heard(messages):
    """Everyone the transcript named as the writer of a message, owner included, in order."""
    names = []
    for message in messages:
        if message.get("role") != "user":
            continue
        found = re.match(r"Message from (.+?):", text_of(message))
        name = found.group(1).replace(" ", "_") if found else None
        if name and name not in names:
            names.append(name)
    return ",".join(names)


def images(messages):
    found = []
    for message in messages:
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if part.get("type") == "image_url":
                found.append(part["image_url"]["url"])
    return found


def well_formed(messages):
    """The rule a strict endpoint enforces: every tool call answered, in order, right after."""
    for index, message in enumerate(messages):
        asked = message.get("tool_calls") or []
        if message.get("role") != "assistant" or not asked:
            continue
        answers = messages[index + 1 : index + 1 + len(asked)]
        if [a.get("role") for a in answers] != ["tool"] * len(asked):
            return False
        if [a.get("tool_call_id") for a in answers] != [c["id"] for c in asked]:
            return False
    return True


def report(body, authorized):
    """Everything the smoke run wants to assert, flattened into the final assistant message."""
    messages = body.get("messages", [])
    system = text_of(messages[0]) if messages else ""
    seen = images(messages)
    requested = [
        call["function"]["name"]
        for message in messages
        if message.get("role") == "assistant"
        for call in message.get("tool_calls") or []
    ]
    fields = {
        "nonce": NONCE,
        "agent": agent_of(messages),
        "heard": heard(messages),
        "model": body.get("model", ""),
        "auth": "yes" if authorized else "no",
        "tools": ",".join(sorted(t["function"]["name"] for t in body.get("tools", []))),
        "system": "yes" if messages and messages[0].get("role") == "system" else "no",
        "calls": ",".join(requested),
        "results": str(sum(1 for m in messages if m.get("role") == "tool")),
        "images": str(len(seen)),
        "png": "yes" if seen and seen[0].startswith(PNG_PREFIX) else "no",
        "valid": "yes" if well_formed(messages) else "no",
        # What the daemon loaded out of the agent's home and put in the system prompt: whether
        # the nonce came back out of ~/memory/MEMORY.md, and which skill folders it indexed.
        "memory": "yes" if NONCE in system else "no",
        "skills": ",".join(sorted(set(re.findall(r"/skills/([^/]+)/SKILL\.md", system)))),
        # And which scheduled tasks it was shown, by id: the prompt index is the only way the
        # smoke run can see that the agent knows what it has already set up.
        "schedules": ",".join(re.findall(r"^- (\d+): ", system, re.M)),
    }
    return " ".join(f"{key}={value}" for key, value in fields.items())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return

        body = json.loads(self.rfile.read(int(self.headers["content-length"] or 0)))
        # Only that a bearer token arrived; the key itself must not be echoed anywhere.
        authorized = (self.headers.get("authorization") or "").startswith("Bearer ")
        who = agent_of(body.get("messages", []))
        calls[who] = calls.get(who, 0) + 1
        nth = calls[who]

        asked = None
        run = tool_call(f"cmd-{nth}", "run_command", {"command": COMMAND, "timeoutMs": TIMEOUT_MS})
        if SCRIPT == "tools" and nth == 1:
            asked = tool_call(f"shot-{nth}", "computer", {"action": "screenshot"})
        elif SCRIPT == "tools" and nth == 2:
            asked = run
        elif SCRIPT == "busy" and nth == 1:
            asked = run
        elif SCRIPT == "worker" and is_worker(body.get("messages", [])):
            asked = run if nth == 1 else None
        elif SCRIPT == "worker" and SENDER and who == SENDER and nth == 1:
            asked = tool_call(
                f"job-{nth}",
                "spawn_task_worker",
                {"brief": f"{NONCE} do the job in your directory and report what happened"},
            )
        elif SCRIPT == "memory" and SENDER and who == SENDER and nth == 1:
            asked = tool_call(
                f"mem-{nth}",
                "remember",
                {"text": f"the smoke run calls this {NONCE}", "scope": "lasting"},
            )
        elif SCRIPT == "web" and SENDER and who == SENDER and nth == 1:
            asked = tool_call(f"web-{nth}", "web_fetch", {"url": URL})
        elif SCRIPT == "talk" and SENDER and who == SENDER and nth == 1:
            asked = tool_call(
                f"msg-{nth}", "send_message", {"to": TO, "text": f"{NONCE} what is your hostname?"}
            )

        message = (
            {"role": "assistant", "content": "", "tool_calls": [asked]}
            if asked
            else {"role": "assistant", "content": report(body, authorized)}
        )

        payload = json.dumps(
            {"choices": [{"index": 0, "message": message, "finish_reason": "stop"}]}
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
