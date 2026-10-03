from __future__ import annotations

import json
import os
import queue
import random
import re
import sys
import threading
import time
from typing import NamedTuple

MAX_NEW = 160
CONTEXT_CHARS = 600
WHOLE_MAX_NEW = 1400


class Stats(NamedTuple):
    provider: str
    model: str
    skipped: bool
    ms: int = 0
    connect_ms: int | None = None
    network_ms: int | None = None
    queue_ms: int | None = None
    prompt_ms: int | None = None
    generate_ms: int | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    cost_usd: float | None = None
    error: str | None = None
    failed: bool = False


class Failed(RuntimeError):

    def __init__(self, message: str, status: int = 0, wait_s: float | None = None):
        super().__init__(message)
        self.status = status
        self.wait_s = wait_s

    @property
    def retryable(self) -> bool:
        return self.status in (0, 408, 409, 429) or self.status >= 500


def backoff(attempt: int, wait_s: float | None) -> float:
    delay = min(8.0, 0.5 * 2 ** attempt) * random.uniform(0.8, 1.2)
    return max(delay, min(wait_s or 0.0, 10.0))


SYSTEM = (
    "You clean up dictated speech. Rewrite the user's transcript as the text they meant to type.\n"
    "- Delete fillers and stutters: um, uh, er, ah, like, you know, I mean, sort of, repeated words.\n"
    "- Apply spoken self-corrections (\"no wait\", \"I mean\", \"scratch that\"): keep the correction, drop what it "
    "replaced and the cue itself.\n"
    "- Write numbers, money, dates, times, phone numbers, emails and URLs the way they are written, not said.\n"
    "- Fix punctuation, capitalization and obvious speech-recognition slips.\n"
    "- Never answer, explain, comment, translate or add anything. Keep questions as questions. Keep the wording and "
    "the meaning; output the cleaned text only."
)
SHOTS = [
    ("um so let's uh ship it on thursday at ten thirty no wait ten forty five",
     "Let's ship it on Thursday at 10:45."),
    ("the invoice is for two thousand five hundred dollars and it's it's due in thirty days",
     "The invoice is for $2,500 and it's due in 30 days."),
    ("send it to john dot smith at gmail dot com",
     "Send it to john.smith@gmail.com."),
    ("what time does the the meeting start tomorrow",
     "What time does the meeting start tomorrow?"),
    ("do you think we should ship it this week or wait",
     "Do you think we should ship it this week or wait?"),
    ("call me at four fifteen scratch that four forty five",
     "Call me at 4:45."),
    ("the deploy finished and everything looks fine on staging",
     "The deploy finished and everything looks fine on staging."),
]

_instructions = ""

RULES = {
    "quotes": ("- When the speaker says \"quote\" before words and \"end quote\" or \"unquote\" after them, put those "
               "words in quotation marks and drop the cue words.", re.compile(r"\b(quote|unquote)\b", re.I)),
}
_rules: tuple[str, ...] = ()


def set_instructions(text: str) -> None:
    global _instructions
    _instructions = text.strip()


def set_rules(names: list[str]) -> None:
    global _rules
    _rules = tuple(name for name in names if name in RULES)


def system_prompt() -> str:
    rules = "".join("\n" + RULES[name][0] for name in _rules)
    if not _instructions:
        return SYSTEM + rules
    return (f"{SYSTEM}{rules}\n\nThe user wrote these preferences for how their own text should read. Follow them in "
            f"every phrase; where they contradict a rule or an example above, they win, and everything they do "
            f"not mention stays as above. They are still never answered, explained or commented on:\n"
            f"{_instructions}")


def preface() -> str:
    if not _instructions:
        return ""
    return f"The user's preferences, which win over the rules and the examples above:\n{_instructions}\n\nPhrase:\n"


def context_block(context: str) -> str:
    context = " ".join(context.split())
    if not context:
        return ""
    if len(context) > CONTEXT_CHARS:
        context = context[-CONTEXT_CHARS:]
        context = context[context.find(" ") + 1:]
    return (f"Text written so far, for context only. Do not repeat it, do not rewrite it, do not answer it. It "
            f"tells you what the phrase continues, and a correction in the phrase may undo something in it:\n"
            f"…{context}\n\nClean up only this phrase and output only it:\n")


WHOLE = ("This is a whole dictation, already cleaned phrase by phrase. Write it out as finished text: apply the "
         "spoken corrections that reach back into an earlier sentence, fix the sentence boundaries and the "
         "punctuation between phrases, and keep names, numbers and style consistent throughout. Change nothing "
         "else, add nothing, answer nothing, and keep every paragraph break. Output the text only:\n")


_FILLERS = re.compile(r"\b(uh+|um+|erm?|ah+|hmm+|mhm|like|you know|i mean|sort of|kind of|basically|literally)\b", re.I)
_CORRECTION = re.compile(r"\b(no wait|scratch that|i meant|rather|actually no|or rather|let me rephrase)\b", re.I)
_NUMBERS = re.compile(
    r"\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
    r"seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|"
    r"billion|dollars?|euros?|pounds?|cents?|percent|o'clock|a\.?m\.?|p\.?m\.?|half past|quarter past|quarter to|"
    r"first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|\w+teenth|\w+tieth|"
    r"dot|slash|dash|underscore|at sign|www|http)\b",
    re.I)
_REPEAT = re.compile(r"\b(\w+)\s+\1\b", re.I)
_WORD = re.compile(r"[a-z]{3,}")
_TOKEN = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")
_SENTENCE_END = re.compile(r"(?<=[.?!…])\s+")


class Corrections(NamedTuple):
    context: int
    reach: int


class Edit(NamedTuple):
    find: str
    replace: str
    at: int


_corrections: Corrections | None = None


def set_corrections(context: int | None, reach: int = 2) -> None:
    global _corrections
    _corrections = None if context is None else Corrections(max(1, context), max(1, min(reach, context)))


def corrections() -> Corrections | None:
    return _corrections


def last_sentences(text: str, count: int) -> str:
    sentences = [piece for piece in _SENTENCE_END.split(" ".join(text.split())) if piece]
    return " ".join(sentences[-count:])


CORRECTING = (
    "\n\nAnswer with a JSON object only: {{\"text\": \"<the cleaned phrase>\", \"edit\": null}}, or with an edit "
    "{{\"find\": \"<span>\", \"replace\": \"<new span>\"}} in place of null.\n"
    "- When the phrase corrects something in the earlier text (\"I mean\", \"no wait\", \"sorry\", \"actually\", "
    "\"make that\", or a restatement that replaces it), put the change in \"edit\": \"find\" is copied exactly from "
    "the earlier text, as short as it can be while occurring there only once; \"replace\" is what it becomes, "
    "written the same way the rest is. Leave the correction and its cue out of \"text\", which may then be empty.\n"
    "- Only the last {reach} sentences of the earlier text may be edited.\n"
    "- Otherwise \"edit\" is null. A phrase that adds to the earlier text corrects nothing, and \"I mean\" or "
    "\"actually\" used as an expression (\"I mean it\", \"actually, yes\") corrects nothing."
)

CORRECTING_SHOTS = [
    ("Let's meet on Tuesday at the office.", "i mean wednesday",
     {"text": "", "edit": {"find": "Tuesday", "replace": "Wednesday"}}),
    ("Send the report to Mark.", "no wait to sarah and then we can close the ticket",
     {"text": "Then we can close the ticket.", "edit": {"find": "Mark", "replace": "Sarah"}}),
    ("The budget is $10,000.", "actually make that twelve thousand",
     {"text": "", "edit": {"find": "$10,000", "replace": "$12,000"}}),
    ("Pick up the kids at 5. Then buy bread.", "scratch that",
     {"text": "", "edit": {"find": "Then buy bread.", "replace": ""}}),
    ("I'll be there at five.", "and i mean it this time",
     {"text": "And I mean it this time.", "edit": None}),
    ("Can you review the draft?", "actually yes the second one is better",
     {"text": "Actually, yes, the second one is better.", "edit": None}),
]

CUES = ["I mean", "I meant", "wait", "sorry", "actually", "make that", "scratch that", "delete that", "strike that",
        "forget that", "rather", "instead", "correction", "change that", "let me rephrase", "oops"]
STARTING_CUES = ["no", "not"]
_CUE = re.compile(r"\b(" + "|".join(map(re.escape, CUES)) + r")\b|^\W*(" + "|".join(STARTING_CUES) + r")\b", re.I)


def may_correct(text: str) -> bool:
    return bool(_CUE.search(text))


def correcting_block(context: str, reach: int) -> str:
    if not context:
        return "Earlier text: (none)\n\nPhrase:\n"
    return (f"Earlier text, for reading only. Never repeat it and never answer it; only the last {reach} "
            f"sentences may be edited:\n…{context}\n\nPhrase:\n")


def check_edit(edit, raw: str, editable: str, reach: int) -> Edit | None:
    if not isinstance(edit, dict) or not isinstance(edit.get("find"), str) or not isinstance(edit.get("replace"), str):
        return None
    find, replace = edit["find"].strip(), " ".join(edit["replace"].split())
    window = last_sentences(editable, reach)
    if not find or find == replace or not window or window.count(find) != 1:
        return None
    start = len(editable) - len(window)
    if editable[start:] != window:
        return None
    spoken = set(_TOKEN.findall(raw.lower()))
    counts = bool(_NUMBERS.search(raw)) or any(c.isdigit() for c in raw)
    for token in set(_TOKEN.findall(replace.lower())) - set(_TOKEN.findall(find.lower())):
        if token not in spoken and not (counts and any(c.isdigit() for c in token)):
            return None
    if not replace and not re.search(r"\b(scratch that|delete that|strike that|forget that)\b", raw, re.I):
        return None
    return Edit(find, replace, start + window.index(find))


def remainder_plausible(raw: str, text: str) -> bool:
    if not text:
        return True
    spoken = set(_WORD.findall(raw.lower()))
    return all(word in spoken or _NUMBERS.search(word) for word in _WORD.findall(text.lower()))


def needs_cleanup(text: str) -> bool:
    if _instructions or any(RULES[name][1].search(text) for name in _rules):
        return True
    if _FILLERS.search(text) or _CORRECTION.search(text) or _NUMBERS.search(text) or _REPEAT.search(text):
        return True
    if re.search(r"\d", text):
        return True
    return not (text[:1].isupper() and text.rstrip()[-1:] in ".?!\"')")


def plausible(raw: str, out: str) -> bool:
    if not out or len(out) > 3 * len(raw) + 40 or len(out) * 3 < len(raw):
        return False
    if re.match(r"^(here'?s|sure|certainly|the cleaned|cleaned text|as an ai)\b", out, re.I):
        return False
    rewritable = set(_WORD.findall(" ".join(_NUMBERS.findall(raw.lower()) + _FILLERS.findall(raw.lower()))))
    words = set(_WORD.findall(raw.lower())) - rewritable
    if len(words) >= 4:
        return sum(word in out.lower() for word in words) * 2 >= len(words)
    return True


class Provider(NamedTuple):
    label: str
    host: str
    path: str
    key_env: str
    budget: str
    quiet: tuple[dict, ...]
    accounting: dict


PROVIDERS = {
    "openrouter": Provider("OpenRouter", "openrouter.ai", "/api/v1/chat/completions", "OPENROUTER_API_KEY",
                           "max_tokens", ({"reasoning": {"enabled": False, "exclude": True}}, {}),
                           {"usage": {"include": True}}),
    "groq": Provider("Groq", "api.groq.com", "/openai/v1/chat/completions", "GROQ_API_KEY",
                     "max_completion_tokens", ({"reasoning_effort": "none", "reasoning_format": "hidden"},
                                               {"reasoning_effort": "low", "reasoning_format": "hidden"}, {}),
                     {}),
}
TIMEOUT_S = 2.5
WHOLE_TIMEOUT_S = 15.0
THINKING = 256
SAYS = {401: "key rejected", 402: "no credits", 403: "model not allowed", 404: "no such model",
        429: "rate limited", 503: "no provider available"}
GROQ_PRICES = {
    "qwen/qwen3.8-27b": (0.80, 4.00),
    "openai/gpt-oss-120b": (0.15, 0.60),
    "openai/gpt-oss-20b": (0.075, 0.30),
    "openai/gpt-oss-safeguard-20b": (0.075, 0.30),
}


def _ms(seconds: float | None) -> int | None:
    return None if seconds is None else round(seconds * 1000)


def _groq_cost(model: str, prompt_tokens: int | None, completion_tokens: int | None) -> float | None:
    price = GROQ_PRICES.get(model)
    if price is None or prompt_tokens is None or completion_tokens is None:
        return None
    return round((prompt_tokens * price[0] + completion_tokens * price[1]) / 1e6, 9)


def provider(key: str | None) -> Provider | None:
    return PROVIDERS.get(key.split(":", 1)[0]) if key and ":" in key else None


def missing_key(key: str) -> str:
    env = provider(key).key_env
    return "" if os.environ.get(env) else f"{env} is not set"


class Remote:

    def __init__(self, key: str, notify=None):
        self.key = key
        self.name = key.split(":", 1)[0]
        self.provider = provider(key)
        self.model = key.split(":", 1)[1]
        self.model_id, _, self.route = self.model.rpartition("@") if "@" in self.model else (self.model, "", "")
        self.notify = notify or (lambda state, message="": None)
        self.conn = None
        self.failed = False
        self.quiet = 0
        self.note = ""
        self.connect_ms: int | None = None
        self.trip_ms = 0.0
        self.shots = [message for phrase, clean in SHOTS
                      for message in ({"role": "user", "content": phrase},
                                      {"role": "assistant", "content": clean})]
        self.json_format = True
        self.wait_s: float | None = None

    def rewrite(self, text: str, context: str = "", retries: int = 0) -> tuple[str, Stats]:
        return self._run(text, context=context, whole=False, deadline=TIMEOUT_S, skippable=True, retries=retries)

    def correct(self, text: str, context: str, editable: str, retries: int = 0) -> tuple[str, Stats, Edit | None]:
        settings = _corrections or Corrections(5, 2)
        self.note = ""
        self.connect_ms, self.trip_ms = None, 0.0
        if message := missing_key(self.key):
            self.note = message
            self._state(False, message)
            return text, self._stats(error=message), None
        try:
            out, usage = self._ask_retrying(retries, text, TIMEOUT_S, last_sentences(context, settings.context),
                                            correcting=settings.reach)
        except Exception as exc:
            self.note = str(exc)
            self._state(False, f"{self.provider.label}: {exc}")
            return text, self._stats(error=str(exc), failed=True), None
        self._state(True)
        try:
            answer = json.loads(out.strip().removeprefix("```json").removeprefix("```").removesuffix("```"))
            cleaned = " ".join(answer["text"].split())
        except Exception:
            self.note = f"{self.model} gave no JSON"
            return text, self._stats(error="malformed answer", **usage), None
        proposed = answer.get("edit")
        edit = check_edit(proposed, text, editable, settings.reach) if proposed else None
        if edit and remainder_plausible(text, cleaned):
            self.note = f"{self.model} edit"
            return cleaned, self._stats(**usage), edit
        if proposed:
            self.note = f"{self.model} unsafe edit"
            return text, self._stats(error="edit not applied", **usage), None
        if not plausible(text, cleaned):
            self.note = f"{self.model} implausible"
            return text, self._stats(error="implausible rewrite", **usage), None
        self.note = self.model
        return cleaned, self._stats(**usage), None

    def whole(self, text: str) -> tuple[str, Stats]:
        return self._run(text, context="", whole=True, deadline=WHOLE_TIMEOUT_S, skippable=False)

    def _run(self, text: str, *, context: str, whole: bool, deadline: float, skippable: bool,
             retries: int = 0) -> tuple[str, Stats]:
        self.note = ""
        self.connect_ms, self.trip_ms = None, 0.0
        if skippable and not needs_cleanup(text):
            return text, self._stats(skipped=True)
        if message := missing_key(self.key):
            self.note = message
            self._state(False, message)
            return text, self._stats(error=message)
        try:
            out, usage = self._ask_retrying(retries, text, deadline, context, whole)
        except Exception as exc:
            self.note = str(exc)
            self._state(False, f"{self.provider.label}: {exc}")
            return text, self._stats(error=str(exc), failed=True)
        self._state(True)
        if not plausible(text, out):
            self.note = f"{self.model} implausible"
            return text, self._stats(error="implausible rewrite", **usage)
        self.note = self.model
        return out, self._stats(**usage)

    def _stats(self, *, skipped: bool = False, **fields) -> Stats:
        return Stats(self.name, self.model, skipped, connect_ms=self.connect_ms, **fields)

    def _ask_retrying(self, retries: int, text: str, deadline_s: float, context: str = "", whole: bool = False,
                      correcting: int | None = None) -> tuple[str, dict]:
        for attempt in range(retries + 1):
            try:
                return self._ask(text, time.monotonic() + deadline_s, context, whole, correcting)
            except (Failed, TimeoutError, OSError) as exc:
                if attempt == retries or (isinstance(exc, Failed) and not exc.retryable):
                    raise
                wait = backoff(attempt, exc.wait_s if isinstance(exc, Failed) else None)
                print(f"cleanup retry {attempt + 1}/{retries} in {wait:.1f} s: {exc}", file=sys.stderr, flush=True)
                time.sleep(wait)
        raise RuntimeError("unreachable")

    def close(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None

    def _state(self, ok: bool, message: str = "") -> None:
        if ok and self.failed:
            self.failed = False
            self.notify("ready")
        elif not ok:
            self.failed = True
            self.notify("error", message)

    def _ask(self, text: str, deadline: float, context: str = "", whole: bool = False,
             correcting: int | None = None) -> tuple[str, dict]:
        def send() -> tuple[int, bytes]:
            return self._round_trip(self._body(text, context, whole, correcting), deadline)

        status, data = send()
        while status != 200:
            if b"reasoning" in data.lower() and self.quiet + 1 < len(self.provider.quiet):
                self.quiet += 1
            elif correcting and self.json_format and (b"response_format" in data.lower() or status in (400, 404)):
                self.json_format = False
            else:
                break
            status, data = send()
        if status != 200:
            raise Failed(f"{status} {SAYS.get(status) or _message(data)}", status, self.wait_s)
        try:
            body = json.loads(data)
            out = body["choices"][0]["message"]["content"]
        except Exception:
            raise RuntimeError(f"bad response: {_message(data)}") from None
        if correcting:
            return out or "", self._usage(body)
        lines = [" ".join(line.split()) for line in (out or "").splitlines()]
        return ("\n".join(lines) if whole else " ".join(lines)).strip().strip('"'), self._usage(body)

    def _usage(self, body: dict) -> dict:
        usage = body.get("usage") or {}
        prompt_tokens, completion_tokens = usage.get("prompt_tokens"), usage.get("completion_tokens")
        queue_s, prompt_s = usage.get("queue_time"), usage.get("prompt_time")
        generate_s = usage.get("completion_time")
        spent = usage.get("total_time")
        if spent is None and (prompt_s is not None or generate_s is not None):
            spent = (prompt_s or 0.0) + (generate_s or 0.0)
        network = None if spent is None else max(0, round(self.trip_ms - ((queue_s or 0.0) + spent) * 1000))
        cost = usage.get("cost") if self.name == "openrouter" else _groq_cost(
            self.model, prompt_tokens, completion_tokens)
        return {"network_ms": network, "queue_ms": _ms(queue_s), "prompt_ms": _ms(prompt_s),
                "generate_ms": _ms(generate_s), "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens, "cost_usd": cost}

    def _body(self, text: str, context: str = "", whole: bool = False, correcting: int | None = None) -> bytes:
        room = (min(WHOLE_MAX_NEW, len(text) // 2 + 300) if whole
                else max(32, min(MAX_NEW, len(text) // 2 + 24))) + (THINKING if self.quiet else 0)
        if correcting:
            system = system_prompt() + CORRECTING.format(reach=correcting)
            shots = [message for earlier, phrase, answer in CORRECTING_SHOTS
                     for message in ({"role": "user", "content": correcting_block(earlier, correcting) + phrase},
                                     {"role": "assistant", "content": json.dumps(answer)})]
            messages = ([{"role": "system", "content": system}] + shots
                        + [{"role": "user", "content": preface() + correcting_block(context, correcting) + text}])
            extra = {"response_format": {"type": "json_object"}} if self.json_format else {}
            room += 60
        else:
            lead = WHOLE if whole else context_block(context)
            messages = ([{"role": "system", "content": system_prompt()}] + self.shots
                        + [{"role": "user", "content": preface() + lead + text}])
            extra = {}
        routing = {"provider": {"order": [self.route], "allow_fallbacks": True, "sort": "latency"}} if self.route else {}
        return json.dumps({
            "model": self.model_id,
            "messages": messages,
            "temperature": 0,
            "stream": False,
            self.provider.budget: room,
            **self.provider.accounting,
            **self.provider.quiet[self.quiet],
            **extra,
            **routing,
        }).encode()

    def _round_trip(self, payload: bytes, deadline: float) -> tuple[int, bytes]:
        import http.client

        headers = {"Authorization": f"Bearer {os.environ[self.provider.key_env]}",
                   "Content-Type": "application/json", "X-Title": "Iridium Live", "Connection": "keep-alive"}
        for retry in (True, False):
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("timed out")
            fresh = self.conn is None
            if fresh:
                self.conn = http.client.HTTPSConnection(self.provider.host, timeout=left)
            self.conn.timeout = left
            if self.conn.sock is not None:
                self.conn.sock.settimeout(left)
            try:
                if fresh:
                    opened = time.perf_counter()
                    self.conn.connect()
                    self.connect_ms = round((time.perf_counter() - opened) * 1000)
                    self.conn.sock.settimeout(left)
                sent = time.perf_counter()
                self.conn.request("POST", self.provider.path, payload, headers)
                response = self.conn.getresponse()
                data = response.read()
                self.trip_ms = (time.perf_counter() - sent) * 1000
                wait = response.getheader("retry-after")
                self.wait_s = float(wait) if wait and wait.replace(".", "", 1).isdigit() else None
                if response.will_close:
                    self.close()
                return response.status, data
            except TimeoutError:
                self.close()
                raise TimeoutError("timed out") from None
            except Exception:
                self.close()
                if fresh or not retry:
                    raise
        raise RuntimeError("unreachable")


def _message(data: bytes) -> str:
    try:
        error = json.loads(data).get("error", {})
        text = error.get("message") or str(error) or data.decode(errors="replace")
    except Exception:
        text = data.decode(errors="replace")
    text = " ".join(text.split())
    return text[:120] + ("…" if len(text) > 120 else "")


BENCH_MODELS = {
    "groq": ["qwen/qwen3.8-27b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"],
    "openrouter": ["openai/gpt-oss-120b:nitro", "qwen/qwen3.8-27b:nitro", "inclusionai/ling-3.0-flash"],
}
BENCH_PACE_S = 0.35
BENCH_BACKOFF_S = 1.0
BENCH_BACKOFF_MAX_S = 60.0
BENCH_QUEUE = 4


class Bench:

    def __init__(self, emit):
        self.emit = emit
        self.jobs: queue.Queue = queue.Queue()
        self.models: dict[str, Remote] = {}
        self.ready: dict[str, float] = {}
        self.delay: dict[str, float] = {}
        self.thread: threading.Thread | None = None

    def configure(self, key: str | None, compare: list[str] | None = None) -> None:
        for remote in self.models.values():
            remote.close()
        name = key.split(":", 1)[0] if key else ""
        offered = compare if compare and name == "openrouter" else BENCH_MODELS.get(name, [])
        others = [model for model in offered if f"{name}:{model}" != key] if key else []
        self.models = {model: Remote(f"{name}:{model}") for model in others}
        self.ready = {model: 0.0 for model in others}
        self.delay = {model: BENCH_BACKOFF_S for model in others}
        if self.models and self.thread is None:
            self.thread = threading.Thread(target=self._work, daemon=True)
            self.thread.start()

    def submit(self, phrase: str, text: str, context: str) -> None:
        if not self.models:
            return
        while self.jobs.qsize() >= BENCH_QUEUE:
            try:
                self.jobs.get_nowait()
            except queue.Empty:
                break
        self.jobs.put((phrase, text, context, dict(self.models)))

    def _work(self) -> None:
        while True:
            phrase, text, context, models = self.jobs.get()
            results: dict[str, dict] = {}
            threads = [threading.Thread(target=self._into, args=(results, model, remote, text, context), daemon=True)
                       for model, remote in models.items()]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            if results:
                self.emit(phrase, [results[model] for model in models if model in results])

    def _into(self, results: dict, model: str, remote: Remote, text: str, context: str) -> None:
        results[model] = self._one(model, remote, text, context)

    def _one(self, model: str, remote: Remote, text: str, context: str) -> dict:
        wait = self.ready.get(model, 0.0) - time.monotonic()
        if wait > 0:
            time.sleep(min(wait, BENCH_BACKOFF_MAX_S))
        at = time.perf_counter()
        out, stats = remote.rewrite(text, context)
        ms = round((time.perf_counter() - at) * 1000)
        error = stats.error
        if error and "429" in error:
            self.delay[model] = min(self.delay.get(model, BENCH_BACKOFF_S) * 2, BENCH_BACKOFF_MAX_S)
            self.ready[model] = time.monotonic() + self.delay[model]
        else:
            if not error:
                self.delay[model] = BENCH_BACKOFF_S
            self.ready[model] = time.monotonic() + BENCH_PACE_S
        return {"provider": remote.name, "model": model, "text": "" if error else out, "ms": ms,
                "prompt_tokens": stats.prompt_tokens, "completion_tokens": stats.completion_tokens,
                "cost_usd": stats.cost_usd, "error": error}

