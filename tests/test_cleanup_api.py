"""The API cleanup provider: the request body for `auto` and a named model, the streamed answer and which model gave
it, the timeout setting and the warm-up."""
import json
import os
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import cleanup  # noqa: E402
import remote  # noqa: E402
from api_stub import AUTO_MODEL, ApiStub  # noqa: E402


class ApiCleanupTest(unittest.TestCase):

    def setUp(self):
        self.key = os.environ.get("CITADEL_API_KEY")
        os.environ["CITADEL_API_KEY"] = "abk_test"
        self.endpoint = (remote.api.base, remote.api.key_env, remote.api.name)
        self.remote = cleanup.Remote("api:auto")

    def tearDown(self):
        cleanup.set_timeout(cleanup.TIMEOUT_S)
        remote.api.update(*self.endpoint)
        if self.key is None:
            os.environ.pop("CITADEL_API_KEY", None)
        else:
            os.environ["CITADEL_API_KEY"] = self.key

    def stub(self) -> ApiStub:
        stub = ApiStub()
        self.addCleanup(stub.close)
        remote.api.update(stub.base, "CITADEL_API_KEY", "Albastar")
        return stub

    def test_provider_is_the_configured_api(self):
        provider = cleanup.provider("api:auto")
        self.assertEqual((provider.label, provider.url, provider.key_env),
                         ("Albastar", "https://api.albastov.com/v1/chat/completions", "CITADEL_API_KEY"))
        remote.api.update("https://openrouter.ai/api/v1/", "CUSTOM_API_KEY", "openrouter.ai")
        provider = cleanup.provider("api:auto")
        self.assertEqual((provider.label, provider.url, provider.key_env),
                         ("openrouter.ai", "https://openrouter.ai/api/v1/chat/completions", "CUSTOM_API_KEY"))
        self.assertEqual(cleanup.missing_key("api:auto"), "CUSTOM_API_KEY is not set")

    def test_auto_body_asks_for_reasoning_off(self):
        body = json.loads(self.remote._body("um so the the meeting is at ten", "Earlier text."))
        self.assertEqual(body["model"], "auto")
        self.assertEqual(body["requirements"], {"reasoning": "off"})
        self.assertTrue(body["stream"])
        self.assertEqual(body["stream_options"], {"include_usage": True})
        self.assertEqual(body["temperature"], 0)
        self.assertGreater(body["max_tokens"], 0)
        for other in ("chat_template_kwargs", "max_completion_tokens", "response_format", "reasoning", "usage"):
            self.assertNotIn(other, body)
        self.assertIn("um so the the meeting is at ten", body["messages"][-1]["content"])

    def test_named_model_body_has_no_requirements(self):
        body = json.loads(cleanup.Remote("api:qwen3.8-27b-gguf")._body("um fine", ""))
        self.assertEqual(body["model"], "qwen3.8-27b-gguf")
        self.assertNotIn("requirements", body)
        self.assertTrue(body["stream"])

    def test_correction_body_auto_and_named(self):
        auto = json.loads(self.remote._body("i mean wednesday", "Let's meet on Tuesday.", correcting=2))
        self.assertEqual(auto["response_format"], {"type": "json_object"})
        self.assertEqual((auto["model"], auto["requirements"]), ("auto", {"reasoning": "off"}))
        named = json.loads(cleanup.Remote("api:gpt-4.1-mini")._body("i mean wednesday", "Let's meet on Tuesday.",
                                                                    correcting=2))
        self.assertEqual(named["model"], "gpt-4.1-mini")
        self.assertNotIn("requirements", named)
        self.assertEqual(named["response_format"], {"type": "json_object"})

    def test_streamed_answer_names_the_model_that_auto_picked(self):
        stub = self.stub()
        text, stats = self.remote.rewrite("um so the meeting is at ten", "")
        self.assertEqual(text, "um so the meeting is at ten")
        self.assertIsNone(stats.error)
        self.assertEqual((stats.provider, stats.model, stats.served), ("api", "auto", AUTO_MODEL))
        self.assertEqual((stats.prompt_tokens, stats.completion_tokens), (10, 3))
        self.assertIsNotNone(stats.ttft_ms)
        request = stub.chats[0]
        self.assertEqual((request["model"], request["requirements"], request["stream"]),
                         ("auto", {"reasoning": "off"}, True))
        self.assertEqual(stub.http[0]["path"], "/v1/chat/completions")
        self.assertEqual(stub.http[0]["headers"]["Authorization"], "Bearer abk_test")
        named = cleanup.Remote("api:parakeet-chat")
        _, stats = named.rewrite("um so the meeting is at ten", "")
        self.assertEqual(stats.served, "parakeet-chat", "a named model is served as named")
        self.assertNotIn("requirements", stub.chats[1])

    def test_a_correction_over_the_stream(self):
        self.stub()
        text, stats, edit = self.remote.correct("i mean wednesday", "Let's meet on Tuesday.",
                                                "Let's meet on Tuesday.")
        self.assertEqual(stats.served, AUTO_MODEL)
        self.assertIsNone(edit)

    def test_base_url_change_takes_the_next_call_there(self):
        first, second = ApiStub(), ApiStub()
        self.addCleanup(first.close)
        self.addCleanup(second.close)
        remote.api.update(first.base)
        self.remote.rewrite("um one", "")
        remote.api.update(second.base)
        self.remote.rewrite("um two", "")
        self.assertEqual((len(first.chats), len(second.chats)), (1, 1))

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

    def test_warm_up_only_for_a_named_model_and_at_most_once_a_minute(self):
        self.assertFalse(self.remote.warm(), "auto picks a loaded model by itself")
        named = cleanup.Remote("api:qwen3.8-27b-gguf")
        body = json.loads(named.warm_body())
        self.assertEqual((body["model"], body["max_tokens"], body["stream"]), ("qwen3.8-27b-gguf", 1, False))
        sent = []
        named._warm = lambda: sent.append(1)
        self.assertTrue(named.warm())
        self.assertFalse(named.warm())
        named.warmed -= cleanup.WARM_EVERY_S
        self.assertTrue(named.warm())
        groq = cleanup.Remote("groq:qwen/qwen3.8-27b")
        self.assertFalse(groq.warm(), "only our API unloads idle models")

    def test_failures_in_plain_words(self):
        self.assertEqual(self.remote._say(cleanup.Failed("401 key rejected", 401)), "Albastar: key rejected")
        self.assertEqual(self.remote._say(cleanup.Failed("503", 503, code="model_loading")),
                         "Albastar is loading the model")
        self.assertEqual(self.remote._say(TimeoutError("timed out")), "Albastar did not answer in time")
        self.assertEqual(self.remote._say(ConnectionRefusedError()), "Albastar is offline")
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

        remote_ = cleanup.Remote("api:auto", stale=lambda: not wanted[0])
        remote_._ask = ask
        started = time.monotonic()
        text, stats = remote_.rewrite("um so the meeting is at ten", retries=3)
        self.assertLess(time.monotonic() - started, 0.3)
        self.assertEqual(len(calls), 1)
        self.assertEqual(text, "um so the meeting is at ten")
        self.assertFalse(stats.failed, "a phrase cleanup no longer wanted is typed as heard, not failed")
        self.assertEqual(stats.error, "cleanup changed in Settings")
        self.assertFalse(remote_.failed)

    def test_a_change_during_the_backoff_ends_the_wait(self):
        changed_at = []

        def ask(*args):
            threading.Timer(0.2, lambda: changed_at.append(time.monotonic())).start()
            raise TimeoutError("timed out")

        remote_ = cleanup.Remote("api:auto", stale=lambda: bool(changed_at))
        remote_._ask = ask
        _, stats, _ = remote_.correct("i mean ten", "The meeting is at nine.", "The meeting is at nine.", retries=5)
        self.assertEqual(stats.error, "cleanup changed in Settings")
        self.assertLess(time.monotonic() - changed_at[0], 0.2)
        self.assertEqual(remote_.tries, 1)


if __name__ == "__main__":
    unittest.main()
