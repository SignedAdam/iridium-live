"""Rewrites a finished phrase into what the speaker meant to type, with a small LLM — on MLX, or over OpenRouter.

Dictation is not prose: it carries fillers, stutters, spoken self-corrections ("no wait, Thursday") and numbers,
money, dates, emails and URLs said as words. The model fixes exactly that and nothing else — it never answers and
never adds. Three things pay for the latency locally: the fixed prompt prefix stays in the KV cache so only the
phrase is ever prefilled, generation drafts itself out of the phrase's own tokens (the output is mostly a copy of
the input) and verifies whole drafts in one pass, and a phrase with nothing to fix never reaches the model at all.
`Remote` runs the same prompt, the same skip and the same plausibility net through OpenRouter instead, for a Mac
that cannot spare the memory: no model is loaded, and a request that is slow or fails hands the raw phrase back.
"""
from __future__ import annotations

import json
import os
import re
import time
from typing import NamedTuple

MODELS = {
    "qwen3-4b": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    "llama-3.2-3b": "mlx-community/Llama-3.2-3B-Instruct-4bit",
}
REMOTE = "openrouter:"  # a cleanup key starting with this names an OpenRouter model id, not a local model
MAX_NEW = 160        # a dictated phrase is short; past this the model is not cleaning any more
NGRAM = (3, 2, 1)    # n-gram sizes tried when drafting, longest first; a bad draft costs one forward pass, no more
DRAFT = 10           # tokens drafted per step

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
SHOTS = [  # the prefix is cached, so extra turns cost load time and KV memory, never per-phrase latency
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
SENTINEL = "\u0000PHRASE\u0000"

_FILLERS = re.compile(r"\b(uh+|um+|erm?|ah+|hmm+|mhm|like|you know|i mean|sort of|kind of|basically|literally)\b", re.I)
_CORRECTION = re.compile(r"\b(no wait|scratch that|i meant|rather|actually no|or rather|let me rephrase)\b", re.I)
_NUMBERS = re.compile(
    r"\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
    r"seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|"
    r"billion|dollars?|euros?|pounds?|cents?|percent|o'clock|a\.?m\.?|p\.?m\.?|half past|quarter past|quarter to|"
    r"first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|dot|slash|dash|underscore|at sign|www|http)\b",
    re.I)
_REPEAT = re.compile(r"\b(\w+)\s+\1\b", re.I)
_WORD = re.compile(r"[a-z]{3,}")


def needs_cleanup(text: str) -> bool:
    """True when the phrase shows something a rewrite could fix. Clean phrases skip the model entirely."""
    if _FILLERS.search(text) or _CORRECTION.search(text) or _NUMBERS.search(text) or _REPEAT.search(text):
        return True
    if re.search(r"\d", text):          # digits that may still want grouping, a time or a currency symbol
        return True
    return not (text[:1].isupper() and text.rstrip()[-1:] in ".?!\"')")


def plausible(raw: str, out: str) -> bool:
    """A rewrite is a rewrite: roughly the same length, and still made of the phrase's own words — except the
    words the rewrite exists to replace (fillers, and numbers that become digits), which must not count against it."""
    if not out or len(out) > 3 * len(raw) + 40 or len(out) * 3 < len(raw):
        return False
    if re.match(r"^(here'?s|sure|certainly|the cleaned|cleaned text|as an ai)\b", out, re.I):
        return False
    rewritable = set(_WORD.findall(" ".join(_NUMBERS.findall(raw.lower()) + _FILLERS.findall(raw.lower()))))
    words = set(_WORD.findall(raw.lower())) - rewritable
    if len(words) >= 4:
        return sum(word in out.lower() for word in words) * 2 >= len(words)
    return True


#: What `mlx_lm.load` itself fetches; asking for the whole repo would also pull the unquantised originals.
PATTERNS = ["*.json", "*.safetensors", "*.py", "tokenizer.model", "*.tiktoken", "*.txt"]


def ensure(key: str, report) -> None:
    """Put the model on disk if it is not, reporting 0..1 as the bytes land."""
    import downloads
    from huggingface_hub import snapshot_download

    repo = MODELS[key]
    try:
        snapshot_download(repo, allow_patterns=PATTERNS, local_files_only=True)
        return
    except Exception:
        pass
    report(0.0)
    with downloads.Progress([downloads.hub_dir(repo)], downloads.hub_bytes(repo), report):
        snapshot_download(repo, allow_patterns=PATTERNS)


class Cleaner:
    """One loaded model. Every method touches MLX, so it belongs to the transcriber thread alone."""

    def __init__(self, model_id: str):
        from mlx_lm import load

        self.model, self.tokenizer = load(model_id)
        self.eos = set(self.tokenizer.eos_token_ids or {self.tokenizer.eos_token_id})
        rendered = self.tokenizer.apply_chat_template(
            [{"role": "system", "content": SYSTEM}]
            + [message for phrase, clean in SHOTS
               for message in ({"role": "user", "content": phrase}, {"role": "assistant", "content": clean})]
            + [{"role": "user", "content": SENTINEL}],
            add_generation_prompt=True, tokenize=False)
        self.head, self.tail = rendered.split(SENTINEL)
        # The chat template's own special tokens are already in the rendered string, so encode it as plain text.
        self._encode = lambda text: self.tokenizer._tokenizer.encode(text, add_special_tokens=False)
        self.reset_cache()
        self.clean("um so it's it's about twenty five dollars")  # compile the prefill, decode and verify graphs

    def rewrite(self, text: str) -> tuple[str, bool]:
        """The phrase as it should be typed, and whether the model actually ran. A phrase with nothing to fix
        never reaches it, and a rewrite that stopped looking like a rewrite is thrown away for the raw phrase."""
        self.accepted = self.steps = 0
        if not needs_cleanup(text):
            return text, False
        out = self.clean(text)
        return (out if plausible(text, out) else text), True

    @property
    def note(self) -> str:
        """What the timing line says about the last rewrite."""
        return f"{self.accepted}/{self.steps} drafted"

    def reset_cache(self) -> None:
        from mlx_lm.models.cache import make_prompt_cache

        self.cache = make_prompt_cache(self.model)
        self.cached: list[int] = []

    def _prefill(self, tokens: list[int]):
        """Bring the cache to `tokens`, reusing the longest prefix it already holds, and return the last logits."""
        import mlx.core as mx
        from mlx_lm.models.cache import trim_prompt_cache

        shared = next((i for i, (a, b) in enumerate(zip(self.cached, tokens)) if a != b),
                      min(len(self.cached), len(tokens)))
        shared = min(shared, len(tokens) - 1)  # the last token must go through the model: its logits are the answer
        if len(self.cached) > shared:
            trim_prompt_cache(self.cache, len(self.cached) - shared)
            del self.cached[shared:]
        logits = None
        for i in range(shared, len(tokens), 512):
            chunk = tokens[i:i + 512]
            logits = self.model(mx.array(chunk)[None], cache=self.cache)
            mx.eval(logits)
        self.cached = list(tokens)
        return logits[0, -1]

    def generate(self, tokens: list[int], corpus: list[int], speculate: bool = True) -> list[int]:
        """Greedy decode. With `speculate`, each step drafts the continuation by matching the last n-gram of the
        output inside `corpus` and verifies the whole draft in one forward pass; rejected drafts are trimmed back
        out of the cache, so the result is the same token sequence either way."""
        import mlx.core as mx
        from mlx_lm.models.cache import trim_prompt_cache

        token = int(mx.argmax(self._prefill(tokens)).item())
        out, self.accepted, self.steps = [], 0, 0
        while token not in self.eos and len(out) < MAX_NEW:
            out.append(token)
            draft = _lookup(corpus, out, DRAFT) if speculate else []
            logits = self.model(mx.array([token] + draft)[None], cache=self.cache)
            picks = [int(t) for t in mx.argmax(logits[0], axis=-1).tolist()]
            self.cached.extend([token] + draft)
            self.steps += 1
            taken = next((i for i, (d, p) in enumerate(zip(draft, picks)) if d != p), len(draft))
            if taken < len(draft):  # the rest of the draft was decoded from tokens that are not going to be there
                trim_prompt_cache(self.cache, len(draft) - taken)
                del self.cached[len(self.cached) - (len(draft) - taken):]
            self.accepted += taken
            for i in range(taken):
                if picks[i] in self.eos or len(out) >= MAX_NEW:
                    return out
                out.append(picks[i])
            token = picks[taken]
        return out

    def clean(self, text: str, speculate: bool = True) -> str:
        """The model's rewrite of one phrase, prefilling only the phrase: the prefix is already in the cache."""
        body = self._encode(text)
        out = self.generate(self._encode(self.head) + body + self._encode(self.tail), body, speculate)
        return self.tokenizer.decode(out).strip()


def _lookup(corpus: list[int], out: list[int], draft: int) -> list[int]:
    """The tokens that followed the output's most recent n-gram the last time it appeared in the phrase."""
    for n in NGRAM:
        if len(out) < n:
            continue
        tail = out[-n:]
        for i in range(len(corpus) - n, -1, -1):
            if corpus[i:i + n] == tail:
                return corpus[i + n:i + n + draft]
    return []


class Provider(NamedTuple):
    """One OpenAI-shaped chat API: where it lives, which key it wants, and how it is asked not to think."""
    label: str
    host: str
    path: str
    key_env: str
    budget: str                 # the field that caps generation
    quiet: tuple[dict, ...]     # ways to ask for no reasoning, best first; one rejected falls through to the next


PROVIDERS = {
    "openrouter": Provider("OpenRouter", "openrouter.ai", "/api/v1/chat/completions", "OPENROUTER_API_KEY",
                           "max_tokens", ({"reasoning": {"enabled": False, "exclude": True}}, {})),
    # Groq's qwen3 models take "none"; gpt-oss only goes down to "low", so a rejected "none" falls through to it.
    "groq": Provider("Groq", "api.groq.com", "/openai/v1/chat/completions", "GROQ_API_KEY",
                     "max_completion_tokens", ({"reasoning_effort": "none", "reasoning_format": "hidden"},
                                               {"reasoning_effort": "low", "reasoning_format": "hidden"}, {})),
}
# One phrase is typed as soon as the rewrite is back, so this budget is dictation latency the speaker feels. A warm
# connection to a fast model answers a phrase in well under a second, and the slowest worth offering lands inside
# 1.3 s; 2.5 s clears their p90 with room for one reconnect, and is still short enough that a stalled request reads
# as a hiccup rather than a hang — the raw phrase is typed instead, which is what the speaker said anyway.
TIMEOUT_S = 2.5
THINKING = 256  # tokens granted on top when a model will not stop reasoning: its rewrite comes after the thinking
#: The statuses worth a word of their own: the API's own sentence is long, and these are what goes wrong.
SAYS = {401: "key rejected", 402: "no credits", 403: "model not allowed", 404: "no such model",
        429: "rate limited", 503: "no provider available"}


def provider(key: str | None) -> Provider | None:
    """The provider a cleanup key names, or None when the key is a local model. Only the first ':' separates the
    provider from the model, because model ids carry colons of their own: "openrouter:qwen/qwen3.8-flash:nitro"."""
    return PROVIDERS.get(key.split(":", 1)[0]) if key and ":" in key else None


def missing_key(key: str) -> str:
    """Why a remote model cannot run yet, or "" when its key is in the environment."""
    env = provider(key).key_env
    return "" if os.environ.get(env) else f"{env} is not set"


class Remote:
    """One model at a provider, over an HTTPS connection that is opened once and kept. Nothing is loaded and no MLX
    memory is touched: the phrase goes out, the rewrite comes back, and anything slower than `TIMEOUT_S` or any
    failure at all gives the raw phrase back instead. The prompt, the skip-when-clean check and the plausibility
    net are the local ones, so a phrase reads the same whichever side cleaned it."""

    def __init__(self, key: str, notify=None):
        self.key = key
        self.provider = provider(key)
        self.model = key.split(":", 1)[1]
        self.notify = notify or (lambda state, message="": None)
        self.conn = None
        self.failed = False  # the last request failed; a success after that is worth an event of its own
        self.quiet = 0       # which way of asking for no reasoning this model turned out to accept
        self.note = ""
        self.messages = ([{"role": "system", "content": SYSTEM}]
                         + [message for phrase, clean in SHOTS
                            for message in ({"role": "user", "content": phrase},
                                            {"role": "assistant", "content": clean})])

    def rewrite(self, text: str) -> tuple[str, bool]:
        """The phrase as it should be typed, and whether the model was asked. The phrase is never lost: a clean
        phrase, a missing key, a timeout, an API error and an implausible rewrite all return the raw text."""
        self.note = ""
        if not needs_cleanup(text):
            return text, False
        if message := missing_key(self.key):
            self.note = message
            self._state(False, message)
            return text, False
        try:
            out = self._ask(text, time.monotonic() + TIMEOUT_S)
        except Exception as exc:
            self.note = str(exc)
            self._state(False, f"{self.provider.label}: {exc}")
            return text, True
        self._state(True)
        if not plausible(text, out):
            self.note = f"{self.model} implausible"
            return text, True
        self.note = self.model
        return out, True

    def close(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None

    def _state(self, ok: bool, message: str = "") -> None:
        """Every phrase that went uncleaned says so, and the first one that comes back after any of them says the
        model is answering again. A run of successes is silent: the slot already announced itself ready."""
        if ok and self.failed:
            self.failed = False
            self.notify("ready")
        elif not ok:
            self.failed = True
            self.notify("error", message)

    def _ask(self, text: str, deadline: float) -> str:
        status, data = self._round_trip(self._body(text), deadline)
        while status != 200 and b"reasoning" in data.lower() and self.quiet + 1 < len(self.provider.quiet):
            self.quiet += 1  # this model does not take that way of being quietened: try the next one down
            status, data = self._round_trip(self._body(text), deadline)
        if status != 200:
            raise RuntimeError(f"{status} {SAYS.get(status) or _message(data)}")
        try:
            out = json.loads(data)["choices"][0]["message"]["content"]
        except Exception:
            raise RuntimeError(f"bad response: {_message(data)}") from None
        return " ".join((out or "").split()).strip('"')

    def _body(self, text: str) -> bytes:
        """The phrase, with generation pinned down: no sampling, no reasoning, and only as many tokens as a rewrite
        of this phrase can need — a model that starts explaining is cut off instead of waited for."""
        room = max(32, min(MAX_NEW, len(text) // 2 + 24)) + (THINKING if self.quiet else 0)
        return json.dumps({
            "model": self.model,
            "messages": self.messages + [{"role": "user", "content": text}],
            "temperature": 0,
            "stream": False,
            self.provider.budget: room,
            **self.provider.quiet[self.quiet],
        }).encode()

    def _round_trip(self, payload: bytes, deadline: float) -> tuple[int, bytes]:
        """One request on the kept connection. A connection that died between phrases costs one reconnect, never
        the phrase: the second attempt runs on what is left of the budget, and nothing is retried past it."""
        import http.client

        headers = {"Authorization": f"Bearer {os.environ[self.provider.key_env]}",
                   "Content-Type": "application/json", "X-Title": "PhononLive", "Connection": "keep-alive"}
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
                self.conn.request("POST", self.provider.path, payload, headers)
                response = self.conn.getresponse()
                data = response.read()
                if response.will_close:
                    self.close()
                return response.status, data
            except TimeoutError:
                self.close()
                raise TimeoutError("timed out") from None
            except Exception:
                self.close()
                if fresh or not retry:  # a connection that was new when it broke is not going to work twice
                    raise
        raise RuntimeError("unreachable")


def _message(data: bytes) -> str:
    """Whatever the API said went wrong, short enough to sit in a one-line event."""
    try:
        error = json.loads(data).get("error", {})
        text = error.get("message") or str(error) or data.decode(errors="replace")
    except Exception:
        text = data.decode(errors="replace")
    text = " ".join(text.split())
    return text[:120] + ("…" if len(text) > 120 else "")
