"""The Vegeta cleanup provider: what goes in the request body, the timeout setting and the warm-up."""
import json
import os
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import cleanup  # noqa: E402


class VegetaCleanupTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get("CITADEL_API_KEY")
        os.environ["CITADEL_API_KEY"] = "abk_test"
        self.remote = cleanup.Remote("vegeta:vegeta-fast")

    def tearDown(self):
        cleanup.set_timeout(cleanup.TIMEOUT_S)
        if self.key is None:
            os.environ.pop("CITADEL_API_KEY", None)
        else:
            os.environ["CITADEL_API_KEY"] = self.key

    def test_provider(self):
        provider = cleanup.provider("vegeta:vegeta-fast")
        self.assertEqual((provider.label, provider.host, provider.path, provider.key_env),
                         ("Vegeta", "citadel.albastov.com", "/v1/chat/completions", "CITADEL_API_KEY"))
        self.assertEqual(self.remote.model_id, "vegeta-fast")
        self.assertEqual(cleanup.missing_key("vegeta:vegeta-fast"), "")

    def test_phrase_body(self):
        body = json.loads(self.remote._body("um so the the meeting is at ten", "Earlier text."))
        self.assertEqual(body["model"], "vegeta-fast")
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(body["temperature"], 0)
        self.assertFalse(body["stream"])
        self.assertIn("max_tokens", body)
        self.assertGreater(body["max_tokens"], 0)
        self.assertNotIn("max_completion_tokens", body)
        self.assertNotIn("response_format", body)
        self.assertNotIn("reasoning", body)
        self.assertNotIn("usage", body)
        self.assertIn("um so the the meeting is at ten", body["messages"][-1]["content"])

    def test_correction_body_asks_for_json(self):
        body = json.loads(self.remote._body("i mean wednesday", "Let's meet on Tuesday.", correcting=2))
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(body["temperature"], 0)

    def test_timeout_setting_reaches_the_phrase_call(self):
        seen = []
        self.remote._ask_retrying = lambda retries, text, deadline_s, *rest, **kw: (seen.append(deadline_s)
                                                                                    or ("Fine.", {}))
        cleanup.set_timeout(4)
        self.remote.rewrite("um fine")
        self.remote.correct("i mean fine", "It is good.", "It is good.")
        self.assertEqual(seen, [4, 4])
        cleanup.set_timeout(0)
        self.remote.rewrite("um fine")
        self.assertEqual(seen[-1], 0.5)

    def test_warm_up_is_tiny_and_at_most_once_a_minute(self):
        body = json.loads(self.remote.warm_body())
        self.assertEqual((body["model"], body["max_tokens"]), ("vegeta-fast", 1))
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        sent = []
        self.remote._warm = lambda: sent.append(1)
        self.assertTrue(self.remote.warm())
        self.assertFalse(self.remote.warm())
        self.remote.warmed -= cleanup.WARM_EVERY_S
        self.assertTrue(self.remote.warm())
        groq = cleanup.Remote("groq:qwen/qwen3.8-27b")
        self.assertFalse(groq.warm(), "only Vegeta unloads idle models")

    def test_failures_in_plain_words(self):
        self.assertEqual(self.remote._say(cleanup.Failed("401 key rejected", 401)), "Vegeta: key rejected")
        self.assertEqual(self.remote._say(cleanup.Failed("503", 503, code="model_loading")),
                         "Vegeta is loading the model")
        self.assertEqual(self.remote._say(TimeoutError("timed out")), "Vegeta did not answer in time")
        self.assertEqual(self.remote._say(ConnectionRefusedError()), "Vegeta is offline")
        self.assertEqual(cleanup.Remote("groq:x")._say(TimeoutError("timed out")), "Groq: timed out")

    def test_turning_cleanup_off_mid_retry_gives_the_phrase_back_as_heard(self):
        """The engine waited out every retry of a provider that had stopped answering, phrase after phrase, so
        turning cleanup off or picking another provider took effect only minutes later."""
        wanted = [True]
        calls = []

        def ask(*args):
            calls.append(time.monotonic())
            wanted[0] = False
            raise TimeoutError("timed out")

        remote = cleanup.Remote("vegeta:vegeta-fast", stale=lambda: not wanted[0])
        remote._ask = ask
        started = time.monotonic()
        text, stats = remote.rewrite("um so the meeting is at ten", retries=3)
        self.assertLess(time.monotonic() - started, 0.3)
        self.assertEqual(len(calls), 1)
        self.assertEqual(text, "um so the meeting is at ten")
        self.assertFalse(stats.failed, "a phrase cleanup no longer wanted is typed as heard, not failed")
        self.assertEqual(stats.error, "cleanup changed in Settings")
        self.assertFalse(remote.failed)

    def test_a_change_during_the_backoff_ends_the_wait(self):
        changed_at = []

        def ask(*args):
            threading.Timer(0.2, lambda: changed_at.append(time.monotonic())).start()
            raise TimeoutError("timed out")

        remote = cleanup.Remote("vegeta:vegeta-fast", stale=lambda: bool(changed_at))
        remote._ask = ask
        _, stats, _ = remote.correct("i mean ten", "The meeting is at nine.", "The meeting is at nine.", retries=5)
        self.assertEqual(stats.error, "cleanup changed in Settings")
        self.assertLess(time.monotonic() - changed_at[0], 0.2)
        self.assertEqual(remote.tries, 1)


if __name__ == "__main__":
    unittest.main()
