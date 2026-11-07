"""The API speech client over HTTP against a stub: order, holding until stop, throttling, fallback and queueing."""
import json
import os
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import remote  # noqa: E402


def tone(mark: int, seconds: float = 0.5) -> np.ndarray:
    """Audio the stub recognises: every sample is mark / 100."""
    return np.full(int(seconds * remote.SAMPLE_RATE), mark / 100, dtype=np.float32)


class Stub:
    """A stand-in for an API's /v1/audio/transcriptions and /v1/models. `script(mark, attempt)` says how to answer."""

    def __init__(self, script):
        self.script = script
        self.lock = threading.Lock()
        self.requests: list[dict] = []
        self.attempts: dict[int, int] = {}
        self.active = 0
        self.most_active = 0
        self.models: dict = {"object": "list", "data": []}
        self.models_status = 200
        self.gets: list[dict] = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                with stub.lock:
                    stub.gets.append({"path": self.path, "headers": dict(self.headers)})
                data = json.dumps(stub.models).encode()
                self.send_response(stub.models_status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                wav = body[body.index(b"RIFF"):body.rindex(b"\r\n--")]
                first = int.from_bytes(wav[44:46], "little", signed=True)
                mark = round(first / 32767 * 100)
                fields = {name: body.split(f'name="{name}"\r\n\r\n'.encode())[1].split(b"\r\n")[0].decode()
                          for name in ("model", "response_format")}
                with stub.lock:
                    attempt = stub.attempts[mark] = stub.attempts.get(mark, 0) + 1
                    stub.requests.append({"mark": mark, "path": self.path, "headers": dict(self.headers),
                                          "fields": fields, "seconds": (len(wav) - 44) / 2 / remote.SAMPLE_RATE})
                    stub.active += 1
                    stub.most_active = max(stub.most_active, stub.active)
                try:
                    delay, status, payload, headers = stub.script(mark, attempt)
                    time.sleep(delay)
                    data = json.dumps(payload).encode()
                    self.send_response(status)
                    for name, value in {"Content-Type": "application/json", "Content-Length": str(len(data)),
                                        **headers}.items():
                        self.send_header(name, value)
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                finally:
                    with stub.lock:
                        stub.active -= 1

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def marks(self) -> list[int]:
        with self.lock:
            return [request["mark"] for request in self.requests]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def ok(text: str, delay: float = 0.0):
    return delay, 200, {"text": text}, {}


class LocalModel:
    def __init__(self):
        self.heard: list[np.ndarray] = []

    def transcribe_array(self, audio):
        self.heard.append(audio)
        return f"local {round(float(audio[0]) * 100)}", None, None


class RemoteTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get(remote.KEY_ENV)
        os.environ[remote.KEY_ENV] = "abk_test"
        self.stubs: list[Stub] = []

    def tearDown(self):
        for stub in self.stubs:
            stub.close()
        if self.key is None:
            os.environ.pop(remote.KEY_ENV, None)
        else:
            os.environ[remote.KEY_ENV] = self.key

    def stub(self, script) -> Stub:
        stub = Stub(script)
        self.stubs.append(stub)
        return stub

    def client(self, stub: Stub | str, **options) -> remote.Client:
        client = remote.Client(remote.Endpoint(stub if isinstance(stub, str) else stub.base), **options)
        self.addCleanup(client.close)
        return client

    def lane(self, stub: Stub, timeout_s: float = 3.0, **options):
        emitted: list[remote.Phrase] = []
        arrived = threading.Condition()

        def emit(phrase):
            with arrived:
                emitted.append(phrase)
                arrived.notify_all()

        def wait_for(count: int, within: float = 5.0) -> list[remote.Phrase]:
            with arrived:
                self.assertTrue(arrived.wait_for(lambda: len(emitted) >= count, within),
                                f"{len(emitted)} of {count} phrases came back")
                return list(emitted)

        lane = remote.Lane(self.client(stub, timeout_s=timeout_s), emit, **options)
        return lane, wait_for

    def test_finals_come_back_in_spoken_order(self):
        delays = {1: 0.6, 2: 0.05, 3: 0.3}
        stub = self.stub(lambda mark, attempt: ok(f"phrase {mark}", delays[mark]))
        lane, wait_for = self.lane(stub)
        started = time.monotonic()
        for mark in (1, 2, 3):
            lane.submit(tone(mark), "take", mark)
        self.assertEqual(lane.pending("take"), 3)
        phrases = wait_for(3)
        self.assertEqual([phrase.text for phrase in phrases], ["phrase 1", "phrase 2", "phrase 3"])
        self.assertEqual([phrase.meta for phrase in phrases], [1, 2, 3])
        self.assertLess(time.monotonic() - started, 1.2, "finals went out one after another, not at once")
        self.assertEqual(stub.most_active, 3)
        for phrase in phrases:
            self.assertGreaterEqual(phrase.answered_at, phrase.sent_at)
            lane.done(phrase)
        self.assertEqual(lane.pending("take"), 0)
        request = stub.requests[0]
        self.assertEqual(request["path"], "/v1/audio/transcriptions")
        self.assertEqual(request["fields"], {"model": "parakeet", "response_format": "json"})
        self.assertEqual(request["headers"]["Authorization"], "Bearer abk_test")
        self.assertEqual(request["headers"]["X-Queue-Timeout"], "10")
        self.assertEqual(request["headers"]["User-Agent"], "Iridium Live")
        self.assertAlmostEqual(request["seconds"], 0.5, places=3)

    def test_configured_model_is_sent(self):
        stub = self.stub(lambda mark, attempt: ok("hello"))
        lane, wait_for = self.lane(stub)
        lane.configure(model="whisper-1", timeout_s=4, fallback="fail")
        lane.submit(tone(1), "take")
        wait_for(1)
        self.assertEqual(stub.requests[0]["fields"]["model"], "whisper-1")
        self.assertEqual((lane.client.timeout_s, lane.fallback), (4.0, "fail"))

    def test_partials_one_at_a_time_and_throttled(self):
        stub = self.stub(lambda mark, attempt: ok(f"so far {attempt}", 0.3))
        partials = remote.Partials(self.client(stub, timeout_s=3.0), every_s=1.0)
        shown = []
        started = time.monotonic()
        while time.monotonic() - started < 2.8:  # requests at 0, 1 and 2 s, answered 0.3 s later; the next at 3 s
            answer = partials.offer(tone(1, 0.3 + time.monotonic() - started), ("take", 1.0))
            if answer:
                shown.append(answer)
            time.sleep(0.05)
        self.assertEqual(len(stub.requests), 3, "one request per second: at 0, 1 and 2 s")
        self.assertEqual(stub.most_active, 1)
        self.assertEqual([text for text, _ in shown], ["so far 1", "so far 2", "so far 3"])
        self.assertGreater(shown[1][1], shown[0][1], "each partial is on the audio so far")

    def test_partial_for_a_closed_phrase_is_dropped(self):
        stub = self.stub(lambda mark, attempt: ok(f"phrase {mark}", 0.3))
        partials = remote.Partials(self.client(stub, timeout_s=3.0), every_s=0.0)
        self.assertIsNone(partials.offer(tone(1), ("take", 1.0)))
        time.sleep(0.05)
        self.assertIsNone(partials.offer(tone(2), ("take", 2.0)), "the first phrase's answer is not here yet")
        time.sleep(0.5)
        self.assertIsNone(partials.offer(tone(2), ("take", 2.0)), "phrase 1's answer came while phrase 2 was open")
        time.sleep(0.5)
        self.assertEqual(partials.offer(tone(2), ("take", 2.0)), ("phrase 2", 0.5))

    def test_failure_falls_back_to_this_mac_for_the_rest_of_the_take(self):
        stub = self.stub(lambda mark, attempt: (0.0, 502, {"error": "bad gateway"}, {}) if mark < 5
                         else ok("api again"))
        model, notices, released = LocalModel(), [], threading.Event()
        lane, wait_for = self.lane(stub, load_local=lambda: model, release_local=released.set,
                                   notice=notices.append)
        lane.submit(tone(1), "take")
        first = wait_for(1)[0]
        self.assertTrue(first.local)
        self.assertEqual(first.text, "local 1")
        self.assertTrue(lane.troubled("take"))
        lane.submit(tone(2), "take")
        second = wait_for(2)[1]
        self.assertEqual((second.text, second.local), ("local 2", True))
        self.assertEqual(stub.marks(), [1], "the rest of the take stays on this Mac")
        self.assertEqual(notices, ["Albastar is offline: using this Mac"])
        for phrase in (first, second):
            lane.done(phrase)
        lane.close("take")
        self.assertTrue(released.wait(2), "this Mac's model is released once no take needs it")
        lane.submit(tone(5), "next")
        third = wait_for(3)[2]
        self.assertEqual((third.text, third.local), ("api again", False))

    def test_failure_fails_the_take_when_asked(self):
        stub = self.stub(lambda mark, attempt: (0.0, 503, {"error": {"code": "queue-timeout", "job_id": "mj_x"}},
                                                 {"Retry-After": "5"}))
        lane, wait_for = self.lane(stub, fallback="fail")
        lane.submit(tone(1), "take")
        wait_for(1)
        lane.submit(tone(2), "take")
        phrases = wait_for(2)
        self.assertEqual([phrase.error for phrase in phrases], ["Albastar is busy", "Albastar is busy"])
        self.assertEqual(stub.marks(), [1], "a failed take sends nothing more")

    def test_slow_answer_is_a_failure(self):
        stub = self.stub(lambda mark, attempt: ok("too late", 2.0))
        lane, wait_for = self.lane(stub, timeout_s=1.0, fallback="fail")
        started = time.monotonic()
        lane.submit(tone(1), "take")
        phrase = wait_for(1)[0]
        self.assertEqual(phrase.error, "Albastar did not answer in 1 s")
        self.assertLess(time.monotonic() - started, 1.5)

    def test_queued_waits_for_the_same_job_within_the_timeout(self):
        stub = self.stub(lambda mark, attempt: (0.0, 503, {"error": {"code": "queued", "job_id": "mj_x"}},
                                                 {"Retry-After": "0.2"}) if attempt == 1 else ok("queued, then done"))
        client = self.client(stub, timeout_s=3.0)
        self.assertEqual(client.transcribe(tone(1)), "queued, then done")
        self.assertEqual(stub.marks(), [1, 1])

    def test_queued_past_the_timeout_fails_at_once(self):
        stub = self.stub(lambda mark, attempt: (0.0, 503, {"error": {"code": "queued", "job_id": "mj_x"}},
                                                 {"Retry-After": "5"}))
        client = self.client(stub, timeout_s=2.0)
        started = time.monotonic()
        with self.assertRaises(remote.Unavailable) as caught:
            client.transcribe(tone(1))
        self.assertEqual(str(caught.exception), "Albastar is busy")
        self.assertLess(time.monotonic() - started, 1.0, "no point waiting 5 s with 2 s to go")

    def test_errors_in_plain_words(self):
        stub = self.stub(lambda mark, attempt: (0.0, 401, {"error": {"code": "invalid_key"}}, {}))
        with self.assertRaises(remote.Unavailable) as caught:
            self.client(stub).transcribe(tone(1))
        self.assertEqual(str(caught.exception), "Albastar: key rejected")
        os.environ.pop(remote.KEY_ENV)
        with self.assertRaises(remote.Unavailable) as caught:
            self.client(stub).transcribe(tone(1))
        self.assertEqual(str(caught.exception), "Albastar: no key")
        closed = Stub(lambda mark, attempt: ok(""))
        base = closed.base
        closed.close()
        os.environ[remote.KEY_ENV] = "abk_test"
        with self.assertRaises(remote.Unavailable) as caught:
            self.client(base).transcribe(tone(1))
        self.assertEqual(str(caught.exception), "Albastar is offline")

    def test_forgotten_take_never_comes_back_and_does_not_hold_up_others(self):
        delays = {1: 0.4, 2: 0.0}
        stub = self.stub(lambda mark, attempt: ok(f"phrase {mark}", delays[mark]))
        lane, wait_for = self.lane(stub)
        lane.submit(tone(1), "cancelled")
        lane.submit(tone(2), "kept")
        lane.forget("cancelled")
        self.assertEqual([phrase.text for phrase in wait_for(1)], ["phrase 2"])
        time.sleep(0.6)
        self.assertEqual(lane.pending(), 1)

    def test_retake_falls_back_while_blocking(self):
        stub = self.stub(lambda mark, attempt: (0.0, 500, {}, {}))
        lane, _ = self.lane(stub, load_local=LocalModel)
        self.assertEqual(remote.Speech(lane, deferred=False).transcribe_array(tone(3))[0], "local 3")
        lane.configure(fallback="fail")
        with self.assertRaises(remote.Unavailable):
            lane.transcribe_now(tone(3))

    def test_after_stop_holds_a_recordings_phrases_until_it_stops(self):
        delays = {1: 0.3, 2: 0.2, 3: 0.1}
        stub = self.stub(lambda mark, attempt: ok(f"phrase {mark}", delays[mark]))
        lane, wait_for = self.lane(stub)
        speech = remote.Speech(lane, holds=True)
        lane.hold("take")
        for mark in (1, 2, 3):
            self.assertIsNone(speech.partial(tone(mark), ("take", float(mark))), "after stop: no captions")
            speech.submit(tone(mark), "take", (float(mark), 0.0, 0.0))
        lane.submit(tone(2), "other")  # another take, not held: it goes out, and comes back in spoken order
        time.sleep(0.3)
        self.assertEqual(stub.marks(), [2], "nothing of the held take went out while it recorded")
        self.assertEqual(lane.pending("take"), 3)
        lane.send_held("take")
        phrases = wait_for(4)
        self.assertEqual([phrase.text for phrase in phrases], ["phrase 1", "phrase 2", "phrase 3", "phrase 2"])
        self.assertEqual([phrase.via for phrase in phrases], ["api"] * 4)
        self.assertEqual(stub.most_active, 3, "all of the recording went out at once when it stopped")
        lane.submit(tone(1), "take")
        self.assertEqual(wait_for(5)[4].text, "phrase 1", "after the stop a late phrase goes at once")

    def test_a_cancelled_held_recording_sends_nothing(self):
        stub = self.stub(lambda mark, attempt: ok(f"phrase {mark}"))
        lane, _ = self.lane(stub)
        lane.hold("take")
        lane.submit(tone(1), "take")
        lane.forget("take")
        lane.send_held("take")
        time.sleep(0.2)
        self.assertEqual((stub.marks(), lane.pending()), ([], 0))

    def test_models_list_and_picker(self):
        payload = {"object": "list", "data": [{"id": "auto"}, {"id": "qwen3.8-27b-gguf"}, {"id": "parakeet"}]}
        stub = self.stub(lambda mark, attempt: ok(""))
        stub.models = payload
        endpoint = remote.Endpoint(stub.base)
        ids = remote.models(endpoint)
        self.assertEqual(ids, ["auto", "qwen3.8-27b-gguf", "parakeet"])
        self.assertEqual(stub.gets[0]["path"], "/v1/models")
        self.assertEqual(stub.gets[0]["headers"]["Authorization"], "Bearer abk_test")
        self.assertEqual(remote.choices(ids), ["auto", "qwen3.8-27b-gguf", "parakeet"])
        self.assertEqual(remote.choices(["gpt-4.1-mini", "auto"]), ["auto", "gpt-4.1-mini"], "auto comes first")
        stub.models = {"object": "list", "data": [{"id": "gpt-4.1-mini"}, {"id": "gpt-4o-transcribe"}]}
        self.assertEqual(remote.choices(remote.models(endpoint)), ["gpt-4.1-mini", "gpt-4o-transcribe"],
                         "a provider without auto gets no Auto")
        stub.models = {"error": {"code": "invalid_key"}}
        stub.models_status = 401
        with self.assertRaises(remote.Unavailable) as caught:
            remote.models(endpoint)
        self.assertEqual(str(caught.exception), "Albastar: key rejected")


if __name__ == "__main__":
    unittest.main()
