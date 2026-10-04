#!/usr/bin/env python3
"""A scripted OpenAI-compatible endpoint for infra/smoke.sh.

Scripted per agent, not per request: every agent shares one endpoint, so the counter is keyed
off the name the daemon puts in the system prompt. The final reply of any script carries what
the stub saw in that agent's transcript, so the smoke run can assert on one string that the
daemon really sent tool definitions, a bearer token, a base64 PNG and named senders.

Binds 127.0.0.1 only: check.sh asserts nothing but the web port listens off loopback.

    STUB_SCRIPT=tools|busy|talk|worker|memory|web|interview|guarded STUB_SENDER=agent STUB_TO=agent \
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
  interview
         STUB_SENDER's first call puts two questions to the owner with ask_owner, its second
         writes a profile carrying the nonce with set_profile, and it reports from the third on.
         Everyone else reports straight away.
  guarded
         STUB_SENDER runs COMMAND (a delete its rules refuse), then asks the owner about it with
         request_approval, then proposes a webhook trigger, then reports. Everyone else reports
         straight away.

A key of the form `status-NNN` (a model in the registry with that api key) makes every call
answer HTTP NNN instead, with `Retry-After: 20` on a 429: the recovery path's 429, 5xx and 401.

STUB_MAX_CHARS=N is the context-overflow mode, on top of any script: a request whose messages
come to more than N characters of JSON is answered HTTP 400 with OpenAI's
`context_length_exceeded` body, the way a real endpoint refuses a transcript past its window.

STUB_FINISH=length is the token-limit mode, on top of any script: each agent's first call is
answered with a run_command call whose arguments stop mid-string and `finish_reason: "length"`,
the way a reply cut off at the output token limit arrives. Its later calls follow the script.

A summariser request (the daemon's compaction prompt as the system text) is answered with a
summary carrying the nonce, whatever the script, and counts as no agent's call.

Real-provider quirks, each on top of any script. By default the stub answers plain JSON; these
make it answer the script's replies as a server-sent event stream instead, the way the daemon
asks for them, and some also refuse requests the way the endpoint they stand for does:

  STUB_STREAM=1          stream, with nothing odd in it.
  STUB_BARE_DATA=1       stream, with `data:` lines that carry nothing between the events.
  STUB_NO_INDEX=1        stream tool calls without `index`, each one's arguments in fragments, and
                         give every tool-call reply a second call (id ending `-twin`), so merging
                         by array position runs the two together.
  STUB_DEEPSEEK=1        stream `reasoning_content` with every reply, and refuse (400) a request
                         carrying tools in which an earlier reply of the stub's comes back without
                         it, as DeepSeek's thinking mode does.
  STUB_SIGNATURES=gemini stream a thought signature on each tool-call reply's first call, in
                         `extra_content.google.thought_signature`, and refuse a request in which
                         one comes back without it, as Gemini 3 does.
  STUB_SIGNATURES=openrouter
                         stream `reasoning_details` in fragments with each tool-call reply, and
                         refuse a request in which they come back changed or missing.
  STUB_ALTERNATE=1       refuse a request with two `user`, `system` or `assistant` messages in a
                         row, as a strict Mistral- or Llama-style chat template does.
  STUB_STRICT_SCHEMA=1   refuse a request whose tool parameters use a keyword outside Gemini's
                         OpenAPI subset, or a type list, as Gemini's OpenAI endpoint does.
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
MAX_CHARS = int(os.environ.get("STUB_MAX_CHARS", "0"))
FINISH = os.environ.get("STUB_FINISH", "")
BARE_DATA = os.environ.get("STUB_BARE_DATA", "") == "1"
NO_INDEX = os.environ.get("STUB_NO_INDEX", "") == "1"
DEEPSEEK = os.environ.get("STUB_DEEPSEEK", "") == "1"
SIGNATURES = os.environ.get("STUB_SIGNATURES", "")
ALTERNATE = os.environ.get("STUB_ALTERNATE", "") == "1"
STRICT_SCHEMA = os.environ.get("STUB_STRICT_SCHEMA", "") == "1"
STREAM = os.environ.get("STUB_STREAM", "") == "1" or BARE_DATA or NO_INDEX or DEEPSEEK or bool(SIGNATURES)
GEMINI_KEYWORDS = {
    "type", "format", "title", "description", "nullable", "enum", "items", "properties", "required",
    "anyOf", "minItems", "maxItems", "minProperties", "maxProperties", "minLength", "maxLength",
    "pattern", "minimum", "maximum", "example", "default", "propertyOrdering",
}
PNG_PREFIX = "data:image/png;base64,iVBORw0KGgo"

calls = {}
cut_off = set()
# What the stub handed out that must come back, keyed by (agent, first call id or reply text).
issued = {}


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


def is_summariser(messages):
    return (text_of(messages[0]) if messages else "").startswith("You are summarising")


def is_worker(messages):
    """Whether this transcript belongs to a task worker. Its name is not known ahead of time,
    so the only handle is what the daemon tells it that it is."""
    return "task worker" in (text_of(messages[0]) if messages else "")


def all_text(message):
    """Every text part, since the daemon joins consecutive user messages into one."""
    content = message.get("content")
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return content if isinstance(content, str) else ""


def heard(messages):
    """Everyone the transcript named as the writer of a message, owner included, in order."""
    names = []
    for message in messages:
        if message.get("role") != "user":
            continue
        for found in re.finditer(r"^(?:Message from (.+?):|(\S+) said here, to the owner:)", all_text(message), re.M):
            name = (found.group(1) or found.group(2)).replace(" ", "_")
            if name not in names:
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


def echo_key(who, message):
    asked = message.get("tool_calls") or []
    return (who, asked[0]["id"] if asked else text_of(message))


def refusal(body):
    """Why the endpoint a quirk mode stands for would refuse this request, or None."""
    messages = body.get("messages", [])
    tools = body.get("tools") or []
    who = agent_of(messages)
    if ALTERNATE:
        roles = [m.get("role") for m in messages]
        for before, after in zip(roles, roles[1:]):
            if before == after and before != "tool":
                return "Conversation roles must alternate user/assistant/user/assistant/..."
    if STRICT_SCHEMA:
        for position, tool in enumerate(tools):
            problem = schema_problem(tool.get("function", {}).get("parameters", {}))
            if problem:
                return (
                    f"Invalid JSON payload received. {problem} at "
                    f"'tools[0].function_declarations[{position}].parameters': Cannot find field."
                )
    for message in messages:
        if message.get("role") != "assistant":
            continue
        given = issued.get(echo_key(who, message))
        if given is None:
            continue
        if DEEPSEEK and tools and message.get("reasoning_content") != given:
            return "The reasoning_content in the thinking mode must be passed back to the API."
        first = (message.get("tool_calls") or [{}])[0]
        if SIGNATURES == "gemini" and first.get("extra_content") != given:
            return f"Function call is missing a thought_signature in functionCall parts: {first.get('id')}"
        if SIGNATURES == "openrouter" and message.get("reasoning_details") != given:
            return f"reasoning_details for {first.get('id')} must be passed back unchanged"
    return None


def schema_problem(schema):
    if not isinstance(schema, dict):
        return None
    for key, value in schema.items():
        if key not in GEMINI_KEYWORDS:
            return f'Unknown name "{key}"'
        if key == "type" and not isinstance(value, str):
            return 'Proto field is not repeating, cannot start list: "type"'
        if key == "enum" and not all(isinstance(option, str) for option in value):
            return "enum values must be strings"
        if key == "properties":
            for sub in value.values():
                problem = schema_problem(sub)
                if problem:
                    return problem
        if key == "items" or key == "anyOf":
            for sub in value if isinstance(value, list) else [value]:
                problem = schema_problem(sub)
                if problem:
                    return problem
    return None


def decorate(who, nth, message):
    """What each quirk mode adds to a scripted reply, remembering what has to come back."""
    asked = message.get("tool_calls") or []
    if NO_INDEX and asked:
        twin = json.loads(json.dumps(asked[0]))
        twin["id"] += "-twin"
        asked.append(twin)
    key = echo_key(who, message)
    if DEEPSEEK:
        message["reasoning_content"] = f"stub reasoning for {who}, step {nth}"
        issued[key] = message["reasoning_content"]
    if SIGNATURES == "gemini" and asked:
        asked[0]["extra_content"] = {"google": {"thought_signature": f"c2ln-{who}-{nth}"}}
        issued[key] = asked[0]["extra_content"]
    if SIGNATURES == "openrouter" and asked:
        message["reasoning_details"] = [
            {"type": "reasoning.text", "text": f"stub thinks about step {nth}", "signature": None,
             "id": f"rs-{nth}", "format": "anthropic-claude-v1", "index": 0},
            {"type": "reasoning.encrypted", "data": f"ZW5j-{who}-{nth}", "id": f"rs-{nth}",
             "format": "anthropic-claude-v1", "index": 1},
        ]
        issued[key] = message["reasoning_details"]
    return message


def halves(text):
    middle = len(text) // 2
    return [piece for piece in (text[:middle], text[middle:]) if piece]


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

    def answer(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def stream(self, message, finish):
        """The reply as OpenAI streams it: a role, then reasoning, text and tool calls in pieces,
        the finish reason, the usage, and `[DONE]`."""
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()

        def emit(payload):
            self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
            if BARE_DATA:
                self.wfile.write(b"data:\n\ndata: \n\n: keep-alive\n\n")

        def chunk(delta, reason=None):
            return {"id": "stub", "object": "chat.completion.chunk",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": reason}]}

        emit(chunk({"role": "assistant", "content": ""}))
        for piece in halves(message.get("reasoning_content", "")):
            emit(chunk({"reasoning_content": piece}))
        for detail in message.get("reasoning_details", []):
            if detail["type"] == "reasoning.text":
                first, rest = halves(detail["text"])
                emit(chunk({"reasoning_details": [{**detail, "text": first}]}))
                emit(chunk({"reasoning_details": [{"type": detail["type"], "index": detail["index"], "text": rest}]}))
            else:
                emit(chunk({"reasoning_details": [detail]}))
        for piece in halves(message.get("content") or ""):
            emit(chunk({"content": piece}))
        for position, call in enumerate(message.get("tool_calls") or []):
            index = {} if NO_INDEX else {"index": position}
            head = {**index, "id": call["id"], "type": "function", "function": {"name": call["function"]["name"], "arguments": ""}}
            if "extra_content" in call:
                head["extra_content"] = call["extra_content"]
            emit(chunk({"tool_calls": [head]}))
            arguments = call["function"]["arguments"]
            third = max(1, len(arguments) // 3)
            for start in range(0, len(arguments), third):
                emit(chunk({"tool_calls": [{**index, "function": {"arguments": arguments[start : start + third]}}]}))
        emit(chunk({}, finish))
        emit({"id": "stub", "object": "chat.completion.chunk", "choices": [],
              "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
        self.wfile.write(b"data: [DONE]\n\n")

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return

        body = json.loads(self.rfile.read(int(self.headers["content-length"] or 0)))
        failing = re.fullmatch(r"Bearer status-(\d{3})", self.headers.get("authorization") or "")
        if failing:
            status = int(failing.group(1))
            self.send_response(status)
            if status == 429:
                self.send_header("retry-after", "20")
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": f"stub answered {status}"}}).encode())
            return
        size = len(json.dumps(body.get("messages", [])))
        if MAX_CHARS and size > MAX_CHARS:
            self.answer(
                400,
                {
                    "error": {
                        "message": f"This model's maximum context length is {MAX_CHARS // 4} tokens. "
                        f"However, your messages resulted in {size // 4} tokens. "
                        "Please reduce the length of the messages.",
                        "type": "invalid_request_error",
                        "param": "messages",
                        "code": "context_length_exceeded",
                    }
                },
            )
            return
        refused = refusal(body)
        if refused:
            self.answer(400, {"object": "error", "message": refused, "type": "BadRequestError", "param": None, "code": 400})
            return
        if is_summariser(body.get("messages", [])):
            summary = {"role": "assistant", "content": f"stub summary {NONCE}: the earlier turns went fine."}
            self.answer(200, {"choices": [{"index": 0, "message": summary, "finish_reason": "stop"}]})
            return
        # Only that a bearer token arrived; the key itself must not be echoed anywhere.
        authorized = (self.headers.get("authorization") or "").startswith("Bearer ")
        who = agent_of(body.get("messages", []))
        if FINISH == "length" and who not in cut_off:
            cut_off.add(who)
            truncated = {
                "id": "cut-1",
                "type": "function",
                "function": {"name": "run_command", "arguments": json.dumps({"command": COMMAND})[:-4]},
            }
            message = {"role": "assistant", "content": "", "tool_calls": [truncated]}
            self.answer(200, {"choices": [{"index": 0, "message": message, "finish_reason": "length"}]})
            return
        calls[who] = calls.get(who, 0) + 1
        nth = calls[who]

        asked = None
        said = ""
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
        elif SCRIPT == "guarded" and SENDER and who == SENDER and nth == 1:
            asked = run
        elif SCRIPT == "guarded" and SENDER and who == SENDER and nth == 2:
            asked = tool_call(
                f"ask-{nth}",
                "request_approval",
                {"category": "delete_files", "target": NONCE, "reason": f"{NONCE} clear out the scratch file"},
            )
        elif SCRIPT == "guarded" and SENDER and who == SENDER and nth == 3:
            asked = tool_call(
                f"hook-{nth}",
                "propose_trigger",
                {"kind": "webhook", "reason": f"{NONCE} wake me when the smoke run posts"},
            )
        elif SCRIPT == "interview" and SENDER and who == SENDER and nth == 1:
            said = "Hi, a couple of questions first."
            asked = tool_call(
                f"ask-{nth}",
                "ask_owner",
                {
                    "questions": [
                        {
                            "question": "What should I mainly do for you?",
                            "header": "Purpose",
                            "options": [
                                {"label": "Spreadsheets", "description": "build and tidy them"},
                                {"label": "Email", "description": "triage and draft replies"},
                                {"label": "Research"},
                            ],
                            "multiple": True,
                        },
                        {"question": "Anything else I should know?"},
                    ]
                },
            )
        elif SCRIPT == "interview" and SENDER and who == SENDER and nth == 2:
            asked = tool_call(
                f"profile-{nth}",
                "set_profile",
                {"profile": f"# {who}\n\nI keep the owner's spreadsheets tidy and triage their email.\n\nNonce: {NONCE}"},
            )

        message = (
            {"role": "assistant", "content": said, "tool_calls": [asked]}
            if asked
            else {"role": "assistant", "content": report(body, authorized)}
        )
        message = decorate(who, nth, message)
        if STREAM:
            self.stream(message, "tool_calls" if asked else "stop")
            return

        payload = json.dumps(
            {"choices": [{"index": 0, "message": message, "finish_reason": "stop"}]}
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
