"""The realtime transcription client against a fake OpenAI-style socket: the session update, appends and commits,
completions matched by item, captions from deltas, failed and error events, reconnecting and falling back."""
import os
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import realtime  # noqa: E402
import remote  # noqa: E402
from api_stub import ApiStub, StubError  # noqa: E402


def tone(mark: int, seconds: float = 0.5) -> np.ndarray:
    """Audio the stub recognises: every sample is mark / 100."""
    return np.full(int(seconds * remote.SAMPLE_RATE), mark / 100, dtype=np.float32)


def until(condition, within: float = 5.0) -> bool:
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return condition()


class RealtimeTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get(remote.KEY_ENV)
        os.environ[remote.KEY_ENV] = "abk_test"
        self.stub = ApiStub()
        self.addCleanup(self.stub.close)
        self.notices: list[str] = []
        self.endpoint = remote.Endpoint(self.stub.base)
        self.stream = realtime.Stream(self.endpoint, notice=self.notices.append)
        self.addCleanup(self.stream.close)

    def tearDown(self):
        if self.key is None:
            os.environ.pop(remote.KEY_ENV, None)
        else:
            os.environ[remote.KEY_ENV] = self.key

    def lane(self, **options):
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

        client = remote.Client(self.endpoint, timeout_s=3.0)
        self.addCleanup(client.close)
        lane = remote.Lane(client, emit, notice=self.notices.append, **options)
        return lane, remote.Speech(lane, live=self.stream), wait_for

    def test_session_update_append_commit_completed(self):
        self.stream.configure("parakeet")
        self.stream.begin()
        self.assertTrue(until(lambda: self.stream.ws is not None), "the socket opens when recording starts")
        phrase = ("take", 1.0)
        for count, seconds in ((1, 0.3), (2, 0.4)):
            self.stream.offer(tone(4, seconds), phrase)
            self.assertTrue(until(lambda: self.stub.kinds(1).count("input_audio_buffer.append") >= count))
        answer = self.stream.transcribe(tone(4, 0.5), timeout_s=3, phrase=phrase)
        self.assertEqual(answer.text, "final 4")
        connection = self.stub.connections[0]
        self.assertEqual(connection["path"], "/v1/realtime?intent=transcription")
        self.assertEqual(connection["headers"]["Authorization"], "Bearer abk_test")
        self.assertEqual(self.stub.sessions[0], {
            "type": "session.update", "event_id": "session",
            "session": {"type": "transcription",
                        "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000},
                                            "transcription": {"model": "parakeet"},
                                            "turn_detection": None}}}})
        kinds = self.stub.kinds(1)
        self.assertEqual(kinds[0], "session.update")
        self.assertEqual(kinds[-1], "input_audio_buffer.commit")
        self.assertGreaterEqual(kinds.count("input_audio_buffer.append"), 3, "the open phrase's audio went out early")
        mark, seconds = self.stub.committed[0]
        self.assertEqual(mark, 4)
        self.assertAlmostEqual(seconds, 0.5, places=3)

    def test_audio_sent_in_pieces_is_the_phrase_resampled(self):
        audio = np.sin(np.arange(8000) / 7.0).astype(np.float32)
        whole = realtime.upsample(audio, 0, realtime.covered(len(audio)))
        joined = np.concatenate([realtime.upsample(audio[:3000], 0, realtime.covered(3000)),
                                 realtime.upsample(audio, realtime.covered(3000), realtime.covered(len(audio)))])
        self.assertEqual(len(whole), 11999)
        np.testing.assert_allclose(joined, whole, atol=1e-6)
        np.testing.assert_allclose(whole[::3], audio[::2], atol=1e-6)

    def test_captions_are_the_deltas_of_the_open_phrase(self):
        self.stream.begin()
        phrase = ("take", 1.0)
        self.stream.offer(tone(6, 0.3), phrase)
        captions = []
        self.assertTrue(until(lambda: captions.append(self.stream.offer(tone(6, 0.4), phrase)) or captions[-1]))
        self.assertEqual(captions[-1][0], "hearing 6")
        self.assertIsNone(self.stream.offer(tone(7, 0.3), ("take", 2.0)), "a caption is for its own phrase only")

    def test_server_without_early_deltas_gives_no_captions(self):
        self.stub.live_deltas = False
        self.stream.begin()
        phrase = ("take", 1.0)
        for seconds in (0.3, 0.4, 0.5):
            self.assertIsNone(self.stream.offer(tone(1, seconds), phrase))
            time.sleep(0.1)
        self.assertEqual(self.stream.transcribe(tone(1), timeout_s=3, phrase=phrase).text, "final 1")

    def test_completions_out_of_order_come_back_in_spoken_order(self):
        delays = {1: 0.5, 2: 0.05, 3: 0.25}
        self.stub.speak = lambda mark, seconds, attempt: (delays[mark], f"final {mark}")
        lane, speech, wait_for = self.lane()
        self.stream.begin()
        for mark in (1, 2, 3):
            speech.submit(tone(mark), "take", (float(mark), 0.0, 0.0))
        phrases = wait_for(3)
        self.assertEqual([phrase.text for phrase in phrases], ["final 1", "final 2", "final 3"])
        self.assertEqual([phrase.via for phrase in phrases], ["api-live"] * 3)
        self.assertEqual([mark for mark, _ in self.stub.committed], [1, 2, 3])
        self.assertEqual(len(self.stub.connections), 1)

    def test_failed_transcription_takes_the_http_way_for_the_rest_of_the_take(self):
        def speak(mark, seconds, attempt):
            if mark == 2:
                time.sleep(0.2)  # after phrase 1 is answered
                raise StubError("model_error", "the model could not transcribe")
            return (0.5 if mark == 3 else 0.05), f"final {mark}"
        self.stub.speak = speak
        lane, speech, wait_for = self.lane()
        self.stream.begin()
        for mark in (1, 2, 3):
            speech.submit(tone(mark), "take", (float(mark), 0.0, 0.0))
        phrases = wait_for(3)
        self.assertEqual([(phrase.text, phrase.via) for phrase in phrases],
                         [("final 1", "api-live"), ("http 2", "api"), ("http 3", "api")])
        self.assertEqual(self.notices, ["Albastar: the model could not transcribe: using Albastar over HTTP"])
        self.stream.begin()
        self.assertEqual(self.stream.transcribe(tone(5), timeout_s=3, phrase=("next", 1.0)).text, "final 5",
                         "the next recording tries live again")

    def test_error_event_fails_the_commit_it_names(self):
        self.stream.begin()
        with self.assertRaises(realtime.Refused) as caught:
            self.stream.transcribe(np.zeros(0, dtype=np.float32), timeout_s=3, phrase=("take", 1.0))
        self.assertEqual(str(caught.exception), "Albastar: buffer too small")
        self.assertEqual(caught.exception.code, "input_audio_buffer_commit_empty")

    def test_a_dropped_socket_is_reopened_and_the_phrase_sent_again(self):
        self.stub.drop_after = 1
        self.stream.begin()
        answer = self.stream.transcribe(tone(3), timeout_s=4, phrase=("take", 1.0))
        self.assertEqual(answer.text, "final 3")
        self.assertEqual(len(self.stub.connections), 2)
        self.assertEqual([mark for mark, _ in self.stub.committed], [3, 3])
        self.assertEqual(self.stub.kinds(2)[0], "session.update", "the new socket starts its own session")

    def test_a_cancelled_phrase_is_cleared_from_the_buffer(self):
        self.stream.begin()
        self.stream.offer(tone(1, 0.4), ("cancelled", 1.0))
        self.assertTrue(until(lambda: "input_audio_buffer.append" in self.stub.kinds(1)))
        self.stream.forget("cancelled")
        self.assertEqual(self.stream.transcribe(tone(2), timeout_s=3, phrase=("next", 1.0)).text, "final 2")
        kinds = self.stub.kinds(1)
        self.assertLess(kinds.index("input_audio_buffer.clear"), len(kinds) - 1)
        self.assertEqual([mark for mark, _ in self.stub.committed], [2], "the cancelled audio was never committed")

    def test_no_live_endpoint_falls_back_at_once(self):
        lane, speech, wait_for = self.lane()
        endpoint = remote.Endpoint(self.stub.base.replace("/v1", "/nowhere"))
        self.stream.endpoint = endpoint
        lane.client.endpoint = remote.Endpoint(self.stub.base)
        with mock.patch.object(realtime, "OPEN_PAUSE_S", 0.01):
            self.stream.begin()
            speech.submit(tone(1), "take", (1.0, 0.0, 0.0))
            phrase = wait_for(1)[0]
        self.assertEqual((phrase.text, phrase.via), ("http 1", "api"))
        self.assertEqual(self.notices, ["Albastar has no live transcription: using Albastar over HTTP"])

    def test_socket_closes_when_idle(self):
        with mock.patch.object(realtime, "KEEP_S", 0.3):
            self.stream.begin()
            self.assertTrue(until(lambda: self.stream.ws is not None), "the socket opens when recording starts")
            self.stream.end()
            self.assertTrue(until(lambda: self.stream.ws is None, 3), "and closes once idle")


if __name__ == "__main__":
    unittest.main()
