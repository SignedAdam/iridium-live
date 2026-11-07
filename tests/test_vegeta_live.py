"""Vegeta Live against a stub Citadel and stream: order, captions, reconnecting, falling back, streamed chat."""
import json
import os
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import cleanup  # noqa: E402
import remote as vegeta  # noqa: E402
import vegeta_live  # noqa: E402
from stream_stub import StreamStub, StubError  # noqa: E402


def tone(mark: int, seconds: float = 0.5) -> np.ndarray:
    """Audio the stub recognises: every sample is mark / 100."""
    return np.full(int(seconds * vegeta.SAMPLE_RATE), mark / 100, dtype=np.float32)


def until(condition, within: float = 5.0) -> bool:
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.01)
    return condition()


class LocalModel:
    def transcribe_array(self, audio):
        return f"local {round(float(audio[0]) * 100)}", None, None


class LiveTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get(vegeta.KEY_ENV)
        os.environ[vegeta.KEY_ENV] = "abk_test"
        self.stub = StreamStub()
        self.addCleanup(self.stub.close)
        self.notices: list[str] = []
        self.stream = vegeta_live.Stream(self.stub.base, notice=self.notices.append)
        self.addCleanup(self.stream.close)

    def tearDown(self):
        if self.key is None:
            os.environ.pop(vegeta.KEY_ENV, None)
        else:
            os.environ[vegeta.KEY_ENV] = self.key

    def lane(self, **options):
        emitted: list[vegeta.Phrase] = []
        arrived = threading.Condition()

        def emit(phrase):
            with arrived:
                emitted.append(phrase)
                arrived.notify_all()

        def wait_for(count: int, within: float = 5.0) -> list[vegeta.Phrase]:
            with arrived:
                self.assertTrue(arrived.wait_for(lambda: len(emitted) >= count, within),
                                f"{len(emitted)} of {count} phrases came back")
                return list(emitted)

        client = vegeta.Client(vegeta.Endpoint(self.stub.base + "/v1", name="Vegeta"), timeout_s=3.0)
        self.addCleanup(client.close)
        lane = vegeta.Lane(client, emit, notice=self.notices.append, **options)
        return lane, wait_for

    def test_session_opens_at_record_start_and_closes_when_idle(self):
        # nothing listens on port 9: the relay after it carries the session
        self.stub.endpoints = lambda session: [{"kind": "lan", "url": "ws://127.0.0.1:9/v1/dictation/stream"},
                                               {"kind": "relay", "url": self.stub.ws_url}]
        with mock.patch.object(vegeta_live, "KEEP_S", 0.3):
            self.stream.begin()
            self.assertTrue(until(lambda: self.stream.ws is not None), "the socket opens when recording starts")
            session = self.stub.sessions[0]
            self.assertEqual(session["key"], "Bearer abk_test")
            self.assertEqual(session["body"]["client"], "Iridium Live")
            self.assertEqual(self.stub.connections, [{"session": "ds_1", "user_agent": "Iridium Live"}])
            self.assertTrue(self.stream.endpoint.startswith(self.stub.ws_url))
            self.assertIn("session=ds_1", self.stream.endpoint)
            time.sleep(0.5)
            self.assertIsNotNone(self.stream.ws, "open while recording, however long")
            self.stream.end()
            self.assertTrue(until(lambda: self.stream.ws is None, 2.0), "closed KEEP_S after the recording")
        self.assertEqual(self.notices, [])

    def test_finals_come_back_in_spoken_order(self):
        delays = {1: 0.4, 2: 0.0, 3: 0.2}
        self.stub.parallel = True
        self.stub.speak = lambda mark, final, seconds, attempt: (delays[mark], f"final {mark}")
        lane, wait_for = self.lane()
        self.stream.begin()
        started = time.monotonic()
        for mark in (1, 2, 3):
            lane.submit(tone(mark), "take", (float(mark), 0.0, 0.0), live=self.stream)
        phrases = wait_for(3)
        self.assertEqual([phrase.text for phrase in phrases], ["final 1", "final 2", "final 3"])
        self.assertLess(time.monotonic() - started, 0.9, "finals went out together on one socket")
        self.assertEqual([phrase.via for phrase in phrases], ["vegeta-live"] * 3)
        self.assertEqual(phrases[0].stream_ms["inference"], 400.0)
        self.assertNotIn("model", phrases[0].stream_ms, "a state is not a duration")
        self.assertNotIn("received", phrases[0].stream_ms, "a clock reading is not a duration")
        self.assertEqual(len(self.stub.connections), 1)
        self.assertEqual(self.stub.http, ["/v1/dictation/sessions"])

    def test_finals_go_first_and_a_newer_caption_replaces_the_older(self):
        self.stub.speak = lambda mark, final, seconds, attempt: (0.4 if mark == 1 else 0.0,
                                                                  f"{'final' if final else 'caption'} {mark}")
        self.stream.begin()
        self.assertTrue(until(lambda: self.stream.ws is not None))
        answered = []
        self.assertTrue(self.stream.caption(tone(1), lambda reply: answered.append(reply["text"])))
        self.assertTrue(until(lambda: self.stub.ran == [("caption", 1)]), "caption 1 is being transcribed")
        self.stream.caption(tone(2), lambda reply: answered.append(reply["text"]))
        self.assertTrue(until(lambda: (1, "caption", 2) in self.stub.received), "caption 2 waits at Vegeta")
        self.stream.caption(tone(3), lambda reply: answered.append(reply["text"]))
        self.assertTrue(until(lambda: (1, "caption", 3) in self.stub.received))
        self.assertEqual(self.stream.transcribe(tone(9), timeout_s=3).text, "final 9")
        self.assertTrue(until(lambda: answered == ["caption 3"]))
        self.assertEqual(self.stub.ran, [("caption", 1), ("final", 9), ("caption", 3)],
                         "the final ran before the waiting caption; caption 2 never ran")
        self.assertEqual(len(self.stub.replaced), 1)
        time.sleep(0.3)
        self.assertEqual(answered, ["caption 3"], "only the newest caption is shown")

    def test_captions_for_a_closed_phrase_are_dropped(self):
        self.stub.speak = lambda mark, final, seconds, attempt: (0.3, f"caption {mark}")
        captions = vegeta_live.Captions(self.stream, every_s=0.0)
        self.stream.begin()
        self.assertTrue(until(lambda: self.stream.ws is not None))
        self.assertIsNone(captions.offer(tone(1), ("take", 1.0)))
        time.sleep(0.05)
        self.assertIsNone(captions.offer(tone(2), ("take", 2.0)), "phrase 2 opened; phrase 1's caption is stale")
        self.assertTrue(until(lambda: captions.answer is not None))
        self.assertEqual(captions.offer(tone(2), ("take", 2.0)), ("caption 2", 0.5))

    def test_a_dropped_socket_is_reopened_and_unanswered_requests_sent_again(self):
        dropped = []

        def drop(header, mark):
            if mark == 2 and not dropped:
                dropped.append(header["id"])
                return True
            return False
        self.stub.drop_on = drop
        lane, wait_for = self.lane()
        self.stream.begin()
        for mark in (1, 2, 3):
            lane.submit(tone(mark), "take", (float(mark), 0.0, 0.0), live=self.stream)
        phrases = wait_for(3)
        self.assertEqual([phrase.text for phrase in phrases], ["final 1", "final 2", "final 3"])
        self.assertEqual([phrase.via for phrase in phrases], ["vegeta-live"] * 3)
        self.assertEqual(len(self.stub.connections), 2)
        self.assertEqual({connection["session"] for connection in self.stub.connections}, {"ds_1"},
                         "the same session carries on")
        self.assertEqual([mark for _, op, mark in self.stub.received if op == "final"].count(2), 2)
        self.assertEqual(self.notices, [])
        self.assertNotIn("/v1/audio/transcriptions", self.stub.http)

    def test_an_expired_ticket_gets_a_new_session_on_reopening(self):
        def drop(header, mark):
            if len(self.stub.connections) == 1:
                self.stub.sessions[0]["expired"] = True
                return True
            return False
        self.stub.drop_on = drop
        self.stream.begin()
        self.assertEqual(self.stream.transcribe(tone(5), timeout_s=4).text, "final 5")
        self.assertEqual([connection["session"] for connection in self.stub.connections], ["ds_1", "ds_2"])
        self.assertEqual(self.notices, [])

    def test_a_quiet_socket_is_pinged_then_reopened(self):
        self.stub.hang = {1}  # the first socket answers nothing, pings included
        with mock.patch.multiple(vegeta_live, QUIET_S=0.2, PONG_TIMEOUT_S=0.3):
            self.stream.begin()
            answer = self.stream.transcribe(tone(4), timeout_s=4)
        self.assertEqual(answer.text, "final 4")
        self.assertEqual(len(self.stub.connections), 2)

    def test_a_socket_that_will_not_open_sends_the_take_over_http(self):
        self.stub.refuse_sockets = True
        lane, wait_for = self.lane()
        self.stream.begin()
        for mark in (1, 2):
            lane.submit(tone(mark), "take", (float(mark), 0.0, 0.0), live=self.stream)
        phrases = wait_for(2)
        self.assertEqual([(phrase.text, phrase.via) for phrase in phrases], [("http 1", "api"), ("http 2", "api")])
        self.assertEqual(self.notices, ["Vegeta Live is offline: using Vegeta"])
        self.stub.refuse_sockets = False
        self.stream.begin()  # the next take tries live again
        lane.submit(tone(3), "next", None, live=self.stream)
        self.assertEqual((wait_for(3)[2].text, wait_for(3)[2].via), ("final 3", "vegeta-live"))
        self.assertEqual(len(self.notices), 1)

    def test_a_socket_dying_mid_take_falls_back_to_http_then_this_mac(self):
        self.stub.http_speak = lambda mark: (502, {"error": "bad gateway"})
        lane, wait_for = self.lane(load_local=LocalModel)
        self.stream.begin()
        lane.submit(tone(1), "take", (1.0, 0.0, 0.0), live=self.stream)
        self.assertEqual(wait_for(1)[0].via, "vegeta-live")

        def drop(header, mark):
            self.stub.refuse_sockets = True
            return True
        self.stub.drop_on = drop
        lane.submit(tone(2), "take", (2.0, 0.0, 0.0), live=self.stream)
        second = wait_for(2)[1]
        self.assertEqual((second.text, second.via), ("local 2", None))
        lane.submit(tone(3), "take", (3.0, 0.0, 0.0), live=self.stream)
        self.assertEqual(wait_for(3)[2].text, "local 3")
        self.assertEqual(self.notices, ["Vegeta Live dropped: using Vegeta", "Vegeta is offline: using this Mac"])
        self.assertEqual(self.stub.http.count("/v1/audio/transcriptions"), 1, "the rest of the take stays here")

    def test_a_refused_session_says_why(self):
        self.stub.session_status = 401
        self.stream.begin()
        with self.assertRaises(vegeta.Unavailable):
            self.stream.transcribe(tone(1), timeout_s=3)
        self.assertEqual(self.notices, ["Vegeta Live: key rejected: using Vegeta"])

    def test_a_request_past_its_time_is_cancelled(self):
        self.stub.speak = lambda mark, final, seconds, attempt: (1.0, "late")
        self.stream.begin()
        with self.assertRaises(TimeoutError):
            self.stream.transcribe(tone(1), timeout_s=0.3)
        self.assertTrue(until(lambda: self.stub.cancelled == [1]))

    def test_a_failed_final_gives_live_up_for_the_take(self):
        def speak(mark, final, seconds, attempt):
            raise StubError("asr_failed", "Parakeet is not running")
        self.stub.speak = speak
        lane, wait_for = self.lane()
        self.stream.begin()
        lane.submit(tone(1), "take", (1.0, 0.0, 0.0), live=self.stream)
        self.assertEqual((wait_for(1)[0].text, wait_for(1)[0].via), ("http 1", "api"))
        self.assertEqual(self.notices, ["Parakeet is not running: using Vegeta"])
        self.assertIsNone(self.stream.captions.offer(tone(1), ("take", 1.0)))


class LiveCleanupTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get(vegeta.KEY_ENV)
        os.environ[vegeta.KEY_ENV] = "abk_test"
        self.stub = StreamStub()
        self.addCleanup(self.stub.close)
        self.stream = vegeta_live.Stream(self.stub.base)
        self.addCleanup(self.stream.close)
        cleanup.set_stream(self.stream)
        self.addCleanup(cleanup.set_stream, None)
        cleanup.set_timeout(4)
        self.addCleanup(cleanup.set_timeout, cleanup.TIMEOUT_S)
        self.states = []
        self.remote = cleanup.Remote("vegeta-live:vegeta-fast", lambda state, message="": self.states.append(
            (state, message)))

    def tearDown(self):
        if self.key is None:
            os.environ.pop(vegeta.KEY_ENV, None)
        else:
            os.environ[vegeta.KEY_ENV] = self.key

    def test_phrase_cleanup_streams_over_the_socket(self):
        self.stub.chat = lambda body: [(0.15, "So ")] + [(0.02, piece) for piece in ("the ", "meeting ", "is at 10.")]
        self.stream.begin()
        text = "um so the the meeting is at ten"
        out, stats = self.remote.rewrite(text, "Earlier text.")
        self.assertEqual(out, "So the meeting is at 10.")
        self.assertEqual(self.stub.chats, [json.loads(self.remote._body(text, "Earlier text."))],
                         "the same body as over HTTP")
        self.assertEqual(stats.provider, "vegeta-live")
        self.assertEqual(stats.completion_tokens, 4)
        self.assertGreaterEqual(stats.ttft_ms, 150)
        self.assertLess(stats.ttft_ms, 400)
        self.assertGreaterEqual(stats.stream_ms["total"], stats.stream_ms["ttft"])
        self.assertIsNone(stats.error)

    def test_correction_comes_back_as_json(self):
        self.stub.chat = lambda body: [(0.0, '{"text": "", "edit": '), (0.0, '{"find": "Tuesday", '),
                                       (0.0, '"replace": "Wednesday"}}')]
        cleanup.set_corrections(5, 2)
        self.addCleanup(cleanup.set_corrections, None, 2)
        out, stats, edit = self.remote.correct("i mean wednesday", "Let's meet on Tuesday.",
                                               "Let's meet on Tuesday.")
        self.assertEqual((edit.find, edit.replace), ("Tuesday", "Wednesday"))
        self.assertEqual(self.stub.chats[0]["response_format"], {"type": "json_object"})
        self.assertEqual(stats.provider, "vegeta-live")

    def test_with_the_socket_down_cleanup_takes_the_http_path(self):
        self.stream.begin()
        self.stream.give_up("Vegeta Live dropped")
        sent = []
        self.remote._http_trip = lambda payload, deadline: (sent.append(json.loads(payload)) or (200, json.dumps(
            {"choices": [{"message": {"content": "Fine."}, "finish_reason": "stop"}]}).encode()))
        out, stats = self.remote.rewrite("um fine")
        self.assertEqual((out, stats.provider), ("Fine.", "vegeta"))
        self.assertEqual(len(sent), 1)
        self.assertEqual(self.stub.chats, [])

    def test_an_error_reply_reads_in_plain_words(self):
        def chat(body):
            raise StubError("gpu-busy", "the GPU is busy")
        self.stub.chat = chat
        out, stats = self.remote.rewrite("um fine")
        self.assertEqual(out, "um fine")
        self.assertTrue(stats.failed)
        self.assertEqual(self.states[-1], ("error", "Vegeta Live is busy"))


if __name__ == "__main__":
    unittest.main()
