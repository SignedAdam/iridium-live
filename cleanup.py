"""Rewrites a finished phrase into what the speaker meant to type, with a small LLM at Groq or OpenRouter.

Dictation is not prose: it carries fillers, stutters, spoken self-corrections ("no wait, Thursday") and numbers,
money, dates, emails and URLs said as words. The model fixes exactly that and nothing else — it never answers and
never adds. `Remote` is the whole of it: nothing is loaded and no memory is taken on this Mac, the phrase goes out
and the rewrite comes back, and anything slow, failed or implausible hands the raw phrase back. A phrase with
nothing to fix never reaches the model at all.
The speaker can add instructions of their own (`set_instructions`), which sit under the fixed rules and send every
phrase to the model, clean or not: they may ask for what the skip cannot see.
Each phrase is cleaned with what came before it in the same recording in front of it, as read-only context: the
model sees the earlier phrases and whatever the app says the dictation is being written into, and still returns
only the phrase it was given, so a correction that reaches back across a phrase boundary has something to reach.
`whole` runs the same model over a finished dictation or a whole note in one pass, which is what fixes the
corrections, the sentence boundaries and the consistency that no single phrase can see. `Bench` runs every other
model of the same provider over a phrase in the background, for comparing them on the speaker's own dictation.
"""
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

MAX_NEW = 160        # a dictated phrase is short; past this the model is not cleaning any more
#: How much of the context in front of a phrase the model is shown. The whole note would be prompt tokens paid for
#: on every phrase, at every provider; the sentence or two a spoken correction can reach back over is near the end.
CONTEXT_CHARS = 600
WHOLE_MAX_NEW = 1400  # the whole-dictation pass writes a text, not a phrase


class Stats(NamedTuple):
    """What one cleanup cost, as the app shows it next to the phrase. Every duration is whole milliseconds, and
    anything the provider did not report (or that does not apply to where the model ran) stays None."""
    provider: str                    # "groq", "openrouter" or "local"
    model: str                       # the model id as it was configured
    skipped: bool                    # the phrase was already clean, so the model was never asked
    ms: int = 0                      # the whole cleanup step, which is what the speaker waits for
    connect_ms: int | None = None    # TCP and TLS, only when this request had to open the connection
    network_ms: int | None = None    # the round trip minus the time the provider says it spent
    queue_ms: int | None = None      # ...and the three halves of that time, as the provider reports them
    prompt_ms: int | None = None
    generate_ms: int | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    cost_usd: float | None = None    # OpenRouter reports it; for Groq it is the token counts at list price
    error: str | None = None         # why the phrase came back raw
    failed: bool = False             # the provider could not be reached or refused: the cleanup did not happen


class Failed(RuntimeError):
    """A request the provider did not answer: its HTTP status (0 for no response) and how long it asked us to wait."""

    def __init__(self, message: str, status: int = 0, wait_s: float | None = None):
        super().__init__(message)
        self.status = status
        self.wait_s = wait_s

    @property
    def retryable(self) -> bool:
        return self.status in (0, 408, 409, 429) or self.status >= 500


def backoff(attempt: int, wait_s: float | None) -> float:
    """Seconds before retry `attempt` (0 first): doubling from 0.5 s with some jitter, at most 8 s, and at least
    what the provider asked for when it said."""
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
SHOTS = [  # the examples the model is shown before the phrase, as a conversation it has already had
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

#: The user's own instructions for the model, set by the `instructions` command and empty by default. They are the
#: same for every phrase, so they live here rather than in one cleaner.
_instructions = ""

#: Optional rules, each a switch in Settings, added to the fixed ones while on: the rule, and the words that make a
#: phrase need the model for it even when it otherwise looks clean.
RULES = {
    "quotes": ("- When the speaker says \"quote\" before words and \"end quote\" or \"unquote\" after them, put those "
               "words in quotation marks and drop the cue words.", re.compile(r"\b(quote|unquote)\b", re.I)),
}
_rules: tuple[str, ...] = ()


def set_instructions(text: str) -> None:
    """Replace the user's own instructions ("" for none). Every request builds its messages fresh, so the next
    phrase is cleaned under them."""
    global _instructions
    _instructions = text.strip()


def set_rules(names: list[str]) -> None:
    """`rules NAME,...`: the optional rules that are on, all others off."""
    global _rules
    _rules = tuple(name for name in names if name in RULES)


def system_prompt() -> str:
    """The fixed rules and the optional ones that are on, with the user's own instructions under them. The rules
    are what keeps a rewrite a rewrite; the preferences below say how the speaker wants the result to read, and
    where the two disagree the speaker wins — the rules and the examples are only the default way of writing a
    phrase out."""
    rules = "".join("\n" + RULES[name][0] for name in _rules)
    if not _instructions:
        return SYSTEM + rules
    return (f"{SYSTEM}{rules}\n\nThe user wrote these preferences for how their own text should read. Follow them in "
            f"every phrase; where they contradict a rule or an example above, they win, and everything they do "
            f"not mention stays as above. They are still never answered, explained or commented on:\n"
            f"{_instructions}")


def preface() -> str:
    """What goes in front of the phrase itself, which is the user's instructions again when there are any. The
    examples sit between the system prompt and the phrase, and a model follows the example nearest to it: told
    to write numbers as words, Groq still answered "Call me at 4:45." to a phrase the examples cover, and "Call
    me at four forty-five." once the preferences were also restated here."""
    if not _instructions:
        return ""
    return f"The user's preferences, which win over the rules and the examples above:\n{_instructions}\n\nPhrase:\n"


def context_block(context: str) -> str:
    """What goes between the fixed prompt and the phrase: the text the phrase continues, which the model reads and
    never rewrites. It is the end of it that matters — a spoken correction reaches back a sentence or two — so only
    the last `CONTEXT_CHARS` are shown, cut at a space so the context never starts mid-word."""
    context = " ".join(context.split())
    if not context:
        return ""
    if len(context) > CONTEXT_CHARS:
        context = context[-CONTEXT_CHARS:]
        context = context[context.find(" ") + 1:]
    return (f"Text written so far, for context only. Do not repeat it, do not rewrite it, do not answer it. It "
            f"tells you what the phrase continues, and a correction in the phrase may undo something in it:\n"
            f"…{context}\n\nClean up only this phrase and output only it:\n")


#: What goes in front of a whole dictation or note instead of a phrase. The rules are the same ones; what changes is
#: that the model now sees every phrase at once, so the corrections, sentence boundaries and inconsistencies that
#: span two phrases are the ones it can finally fix.
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
    """Spoken corrections that reach back into earlier text, when they are switched on."""
    context: int  # sentences of the earlier text the model reads
    reach: int    # ...of which the last this many are the only ones it may edit


class Edit(NamedTuple):
    """One change to the earlier text, checked: `find` occurs once in the editable window, at `at`."""
    find: str
    replace: str
    at: int


_corrections: Corrections | None = None


def set_corrections(context: int | None, reach: int = 2) -> None:
    """`corrections CONTEXT REACH` or `corrections off` (None). Every phrase cleaned after this follows it."""
    global _corrections
    _corrections = None if context is None else Corrections(max(1, context), max(1, min(reach, context)))


def corrections() -> Corrections | None:
    return _corrections


def last_sentences(text: str, count: int) -> str:
    """The end of `text`, `count` sentences of it."""
    sentences = [piece for piece in _SENTENCE_END.split(" ".join(text.split())) if piece]
    return " ".join(sentences[-count:])


#: What the model is told on top of the rules when corrections are on. It answers in JSON from then on, so the phrase
#: and a change to what came before it arrive apart, and neither is mistaken for the other.
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

#: The examples in JSON form, with earlier text: (earlier text, phrase, answer). Few, because every token of them is
#: paid on every correcting phrase, and Groq's free tier allows 8,000 tokens a minute.
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

#: The words a spoken correction starts with or turns on. Only a phrase that has one is asked for an edit; the rest
#: are cleaned the ordinary way, which keeps every other phrase as cheap as it was.
CUES = ["I mean", "I meant", "wait", "sorry", "actually", "make that", "scratch that", "delete that", "strike that",
        "forget that", "rather", "instead", "correction", "change that", "let me rephrase", "oops"]
STARTING_CUES = ["no", "not"]  # only at the start: they are everywhere else in speech
_CUE = re.compile(r"\b(" + "|".join(map(re.escape, CUES)) + r")\b|^\W*(" + "|".join(STARTING_CUES) + r")\b", re.I)


def may_correct(text: str) -> bool:
    """Whether a phrase could be correcting earlier text: it carries a correction cue."""
    return bool(_CUE.search(text))


def correcting_block(context: str, reach: int) -> str:
    """The earlier text and the phrase's heading, for a phrase that may correct what came before it."""
    if not context:
        return "Earlier text: (none)\n\nPhrase:\n"
    return (f"Earlier text, for reading only. Never repeat it and never answer it; only the last {reach} "
            f"sentences may be edited:\n…{context}\n\nPhrase:\n")


def check_edit(edit, raw: str, editable: str, reach: int) -> Edit | None:
    """The model's edit, if it is safe to make. `find` must occur exactly once in the last `reach` sentences of
    `editable` (this recording's text), and every word `replace` brings in must come from what was just said:
    the model moves the speaker's words into place, it never writes its own. Deleting needs an explicit cue."""
    if not isinstance(edit, dict) or not isinstance(edit.get("find"), str) or not isinstance(edit.get("replace"), str):
        return None
    find, replace = edit["find"].strip(), " ".join(edit["replace"].split())
    window = last_sentences(editable, reach)
    if not find or find == replace or not window or window.count(find) != 1:
        return None
    start = len(editable) - len(window)
    if editable[start:] != window:  # the editable text was not one line of single spaces: nothing to anchor to
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
    """What is left of a phrase once its correction went into an edit: possibly nothing, otherwise only the
    phrase's own words (and numbers written as digits)."""
    if not text:
        return True
    spoken = set(_WORD.findall(raw.lower()))
    return all(word in spoken or _NUMBERS.search(word) for word in _WORD.findall(text.lower()))


def needs_cleanup(text: str) -> bool:
    """True when the phrase shows something a rewrite could fix. Clean phrases skip the model entirely — unless
    the user set instructions of their own, which may well ask for a change this test cannot see ("always write
    numbers as words", "no exclamation marks"): with those set, every phrase goes to the model."""
    if _instructions or any(RULES[name][1].search(text) for name in _rules):
        return True
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


class Provider(NamedTuple):
    """One OpenAI-shaped chat API: where it lives, which key it wants, and how it is asked not to think."""
    label: str
    host: str
    path: str
    key_env: str
    budget: str                 # the field that caps generation
    quiet: tuple[dict, ...]     # ways to ask for no reasoning, best first; one rejected falls through to the next
    accounting: dict            # what to add to the body to be told what the request cost


PROVIDERS = {
    "openrouter": Provider("OpenRouter", "openrouter.ai", "/api/v1/chat/completions", "OPENROUTER_API_KEY",
                           "max_tokens", ({"reasoning": {"enabled": False, "exclude": True}}, {}),
                           {"usage": {"include": True}}),  # ...which is the only way it reports the price
    # Groq's qwen3 models take "none"; gpt-oss only goes down to "low", so a rejected "none" falls through to it.
    "groq": Provider("Groq", "api.groq.com", "/openai/v1/chat/completions", "GROQ_API_KEY",
                     "max_completion_tokens", ({"reasoning_effort": "none", "reasoning_format": "hidden"},
                                               {"reasoning_effort": "low", "reasoning_format": "hidden"}, {}),
                     {}),  # Groq times and counts every request in `usage` without being asked
}
# One phrase is typed as soon as the rewrite is back, so this budget is dictation latency the speaker feels. A warm
# connection to a fast model answers a phrase in well under a second, and the slowest worth offering lands inside
# 1.3 s; 2.5 s clears their p90 with room for one reconnect, and is still short enough that a stalled request reads
# as a hiccup rather than a hang — the raw phrase is typed instead, which is what the speaker said anyway.
TIMEOUT_S = 2.5
# A whole dictation or note is not latency the speaker waits on mid-phrase: it is asked for once, when the recording
# has already stopped or the note is being cleaned on purpose, and it writes far more tokens than a phrase does.
WHOLE_TIMEOUT_S = 15.0
THINKING = 256  # tokens granted on top when a model will not stop reasoning: its rewrite comes after the thinking
#: The statuses worth a word of their own: the API's own sentence is long, and these are what goes wrong.
SAYS = {401: "key rejected", 402: "no credits", 403: "model not allowed", 404: "no such model",
        429: "rate limited", 503: "no provider available"}
#: Groq's published list price per million tokens, input then output, for the chat models it sells by the token
#: (https://console.groq.com/docs/models, read 2026-10-01). The models priced "contact sales" there, and anything
#: added since, are simply absent: a phrase cleaned by one of those reports no cost rather than a wrong one.
GROQ_PRICES = {
    "qwen/qwen3.8-27b": (0.80, 4.00),
    "openai/gpt-oss-120b": (0.15, 0.60),
    "openai/gpt-oss-20b": (0.075, 0.30),
    "openai/gpt-oss-safeguard-20b": (0.075, 0.30),
}


def _ms(seconds: float | None) -> int | None:
    """A duration a provider reported in seconds, in whole milliseconds."""
    return None if seconds is None else round(seconds * 1000)


def _groq_cost(model: str, prompt_tokens: int | None, completion_tokens: int | None) -> float | None:
    """What one Groq request cost at list price, or None for a model with no published per-token price."""
    price = GROQ_PRICES.get(model)
    if price is None or prompt_tokens is None or completion_tokens is None:
        return None
    return round((prompt_tokens * price[0] + completion_tokens * price[1]) / 1e6, 9)


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
        self.name = key.split(":", 1)[0]
        self.provider = provider(key)
        self.model = key.split(":", 1)[1]
        self.notify = notify or (lambda state, message="": None)
        self.conn = None
        self.failed = False  # the last request failed; a success after that is worth an event of its own
        self.quiet = 0       # which way of asking for no reasoning this model turned out to accept
        self.note = ""
        self.connect_ms: int | None = None  # what opening the connection cost the last phrase, if it had to
        self.trip_ms = 0.0                  # ...and what its last round trip took, wire and provider together
        self.shots = [message for phrase, clean in SHOTS
                      for message in ({"role": "user", "content": phrase},
                                      {"role": "assistant", "content": clean})]
        self.json_format = True  # asked for a JSON object, until a provider turns that down
        self.wait_s: float | None = None  # what the last response said to wait before asking again

    def rewrite(self, text: str, context: str = "", retries: int = 0) -> tuple[str, Stats]:
        """The phrase as it should be typed, and what the cleanup cost. `context` is the text the phrase continues,
        sent for the model to read and never to rewrite. A request the provider fails is tried `retries` more times.
        The phrase is never lost: a clean phrase, a missing key, a failure and an implausible rewrite all return the
        raw text, and `Stats.failed` says when the provider was the reason."""
        return self._run(text, context=context, whole=False, deadline=TIMEOUT_S, skippable=True, retries=retries)

    def correct(self, text: str, context: str, editable: str, retries: int = 0) -> tuple[str, Stats, Edit | None]:
        """`rewrite` with corrections on: the phrase, and at most one checked edit to `editable` (this recording's
        text so far, the end of `context`). Anything malformed, implausible or unsafe gives the raw phrase back and
        no edit."""
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
        if proposed:  # the model took the correction out of the phrase for an edit that cannot be made: keep it said
            self.note = f"{self.model} unsafe edit"
            return text, self._stats(error="edit not applied", **usage), None
        if not plausible(text, cleaned):
            self.note = f"{self.model} implausible"
            return text, self._stats(error="implausible rewrite", **usage), None
        self.note = self.model
        return cleaned, self._stats(**usage), None

    def whole(self, text: str) -> tuple[str, Stats]:
        """A finished dictation or a whole note in one pass, under the longer budget a text deserves. Nothing is
        skipped: what this pass fixes spans phrases, which the per-phrase test cannot see."""
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
        """One phrase's `Stats`, with what this object knows already filled in. `ms` belongs to the caller: the
        wait it measures is the caller's."""
        return Stats(self.name, self.model, skipped, connect_ms=self.connect_ms, **fields)

    def _ask_retrying(self, retries: int, text: str, deadline_s: float, context: str = "", whole: bool = False,
                      correcting: int | None = None) -> tuple[str, dict]:
        """`_ask`, tried again up to `retries` times after a timeout, a lost connection, a rate limit or a server
        error, each time under a fresh deadline and after a growing wait. A refused key or model is not retried."""
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
        """Every phrase that went uncleaned says so, and the first one that comes back after any of them says the
        model is answering again. A run of successes is silent: the slot already announced itself ready."""
        if ok and self.failed:
            self.failed = False
            self.notify("ready")
        elif not ok:
            self.failed = True
            self.notify("error", message)

    def _ask(self, text: str, deadline: float, context: str = "", whole: bool = False,
             correcting: int | None = None) -> tuple[str, dict]:
        """The rewrite and what the provider says it cost, in one round trip — two when the model turns out not to
        take the way it was asked not to think, or not to answer in JSON. With `correcting` (the edit reach), the
        answer is the model's JSON as it came, for the caller to parse before anything is tidied."""
        def send() -> tuple[int, bytes]:
            return self._round_trip(self._body(text, context, whole, correcting), deadline)

        status, data = send()
        while status != 200:
            if b"reasoning" in data.lower() and self.quiet + 1 < len(self.provider.quiet):
                self.quiet += 1  # this model does not take that way of being quietened: try the next one down
            elif correcting and self.json_format and b"response_format" in data.lower():
                self.json_format = False  # nor a JSON object asked for: the prompt alone asks for it
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
        # A phrase is one line; a whole text keeps the paragraphs it was given, tidied line by line.
        lines = [" ".join(line.split()) for line in (out or "").splitlines()]
        return ("\n".join(lines) if whole else " ".join(lines)).strip().strip('"'), self._usage(body)

    def _usage(self, body: dict) -> dict:
        """What the response says the request cost, as `Stats` fields. Groq times every request in `usage`, in
        seconds, and charges by the token, so its price comes from `GROQ_PRICES`; OpenRouter reports no timings
        but, with usage accounting asked for, the amount it actually charged."""
        usage = body.get("usage") or {}
        prompt_tokens, completion_tokens = usage.get("prompt_tokens"), usage.get("completion_tokens")
        queue_s, prompt_s = usage.get("queue_time"), usage.get("prompt_time")
        generate_s = usage.get("completion_time")
        spent = usage.get("total_time")
        if spent is None and (prompt_s is not None or generate_s is not None):
            spent = (prompt_s or 0.0) + (generate_s or 0.0)
        # Everything the round trip took that the provider does not account for is the wire and our own side.
        network = None if spent is None else max(0, round(self.trip_ms - ((queue_s or 0.0) + spent) * 1000))
        cost = usage.get("cost") if self.name == "openrouter" else _groq_cost(
            self.model, prompt_tokens, completion_tokens)
        return {"network_ms": network, "queue_ms": _ms(queue_s), "prompt_ms": _ms(prompt_s),
                "generate_ms": _ms(generate_s), "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens, "cost_usd": cost}

    def _body(self, text: str, context: str = "", whole: bool = False, correcting: int | None = None) -> bytes:
        """The phrase, with generation pinned down: no sampling, no reasoning, and only as many tokens as a rewrite
        of this phrase can need — a model that starts explaining is cut off instead of waited for. The system
        message, the preface and the context are built here, so instructions the user changed between phrases, and
        the text this phrase continues, are in this one. A whole dictation is given room to be written out; a phrase
        that may correct earlier text, room for the JSON around it and one edit."""
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
        return json.dumps({
            "model": self.model,
            "messages": messages,
            "temperature": 0,
            "stream": False,
            self.provider.budget: room,
            **self.provider.accounting,
            **self.provider.quiet[self.quiet],
            **extra,
        }).encode()

    def _round_trip(self, payload: bytes, deadline: float) -> tuple[int, bytes]:
        """One request on the kept connection, timed: opening the connection is counted on its own, since that is
        the cold phrase's extra cost, and `trip_ms` is the request itself. A connection that died between phrases
        costs one reconnect, never the phrase: the second attempt runs on what is left of the budget, and nothing
        is retried past it."""
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
                    self.conn.connect()  # TCP and TLS, which is most of what a cold phrase waits for
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


#: Every model the app offers on each provider, in the order the app lists them (`Settings.cleanupProviders` in
#: Sources/Settings.swift). Benchmarking runs the ones that are not the chosen model over the same phrase.
BENCH_MODELS = {
    "groq": ["qwen/qwen3.8-27b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"],
    "openrouter": ["openai/gpt-oss-120b:nitro", "qwen/qwen3.8-27b:nitro", "inclusionai/ling-3.0-flash"],
}
BENCH_PACE_S = 0.35         # quiet between two requests to the same model, so a fast speaker cannot burst a provider
BENCH_BACKOFF_S = 1.0       # the first wait after a 429, doubling for every 429 in a row...
BENCH_BACKOFF_MAX_S = 60.0  # ...up to this, and back to the first wait after a request that worked
BENCH_QUEUE = 4             # phrases waiting to be benchmarked; past this the oldest is dropped, never the newest


class Bench:
    """Runs every other model of the chosen provider over a phrase, in a thread of its own.

    What the speaker waits for is the cleanup of their own model, so nothing here is ever on that path: the phrase
    is handed over after it has been typed, the comparisons run behind it, and a speaker who outruns them loses the
    oldest phrase in the queue rather than the newest. Each model keeps its own pace and its own backoff, so one
    model being rate limited neither delays the others nor stops the run; what it said instead is recorded as that
    model's error for the phrase.
    """

    def __init__(self, emit):
        self.emit = emit            # emit(phrase_id, [result, ...]) once a phrase has been through every model
        self.jobs: queue.Queue = queue.Queue()
        self.models: dict[str, Remote] = {}
        self.ready: dict[str, float] = {}   # per model, the monotonic time it may be asked again
        self.delay: dict[str, float] = {}   # ...and how long the next 429 would hold it off
        self.thread: threading.Thread | None = None

    def configure(self, key: str | None) -> None:
        """Compare against the other models of `key`'s provider. A local model, no model and benchmarking switched
        off all pass None, which leaves nothing to run."""
        for remote in self.models.values():
            remote.close()
        name = key.split(":", 1)[0] if key else ""
        others = [model for model in BENCH_MODELS.get(name, []) if f"{name}:{model}" != key]
        self.models = {model: Remote(f"{name}:{model}") for model in others}
        self.ready = {model: 0.0 for model in others}
        self.delay = {model: BENCH_BACKOFF_S for model in others}
        if self.models and self.thread is None:
            self.thread = threading.Thread(target=self._work, daemon=True)
            self.thread.start()

    def submit(self, phrase: str, text: str, context: str) -> None:
        """Compare the models on one phrase, which its own model has already cleaned."""
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
        """One model's answer, on a thread of its own: a model being held off after a 429 must not hold up the
        others, and one phrase through every model is one event."""
        results[model] = self._one(model, remote, text, context)

    def _one(self, model: str, remote: Remote, text: str, context: str) -> dict:
        """One model's answer to one phrase, after whatever wait that model is under."""
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
