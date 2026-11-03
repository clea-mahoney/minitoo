import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("studio_cloud", ROOT / "apps/live-studio/cloud.py")
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)

BASE = {"FIREBASE_DB_URL": "https://example.firebaseio.com", "FIREBASE_API_KEY": "test-key"}
LOGIN = {"idToken": "test-token", "refreshToken": "test-refresh", "expiresIn": "3600"}


class CloudTests(unittest.TestCase):
    def test_existing_anonymous_project_needs_no_password(self):
        with patch.dict(os.environ, dict(BASE, FIREBASE_AUTH_MODE="anonymous"), clear=True), patch.object(cloud, "request", return_value=LOGIN) as request:
            client = cloud.Firebase()
            self.assertEqual(client.auth(), "test-token")
            url, body, method = request.call_args.args
            self.assertIn("accounts:signUp", url)
            self.assertEqual(body, {"returnSecureToken": True})
            self.assertEqual(method, "POST")

    def test_password_login_remains_the_default(self):
        with patch.dict(os.environ, BASE, clear=True):
            with self.assertRaises(ValueError):
                cloud.Firebase()
        with patch.dict(os.environ, dict(BASE, FIREBASE_EMAIL="relay@example.com", FIREBASE_PASSWORD="test-password"), clear=True), patch.object(cloud, "request", return_value=LOGIN) as request:
            cloud.Firebase().auth()
            self.assertIn("signInWithPassword", request.call_args.args[0])

    def test_valid_tokens_are_reused(self):
        with patch.dict(os.environ, dict(BASE, FIREBASE_AUTH_MODE="anonymous"), clear=True), patch.object(cloud, "request", return_value=LOGIN) as request:
            client = cloud.Firebase()
            client.auth()
            client.auth()
            self.assertEqual(request.call_count, 1)

    def test_expired_token_is_refreshed_without_creating_another_account(self):
        refreshed = {"id_token": "new-token", "refresh_token": "new-refresh", "expires_in": "3600"}
        with patch.dict(os.environ, dict(BASE, FIREBASE_AUTH_MODE="anonymous"), clear=True), patch.object(cloud, "request", return_value=LOGIN) as request, patch.object(cloud, "request_form", return_value=refreshed) as form:
            client = cloud.Firebase()
            client.auth()
            client.expires = 0
            self.assertEqual(client.auth(), "new-token")
            self.assertEqual(request.call_count, 1)
            self.assertEqual(form.call_args.args[1], {"grant_type": "refresh_token", "refresh_token": "test-refresh"})

    def test_database_errors_do_not_expose_tokens(self):
        with patch.dict(os.environ, dict(BASE, FIREBASE_AUTH_MODE="anonymous"), clear=True):
            client = cloud.Firebase()
            client.token = "private-token"
            client.expires = float("inf")
            with patch.object(cloud, "request", side_effect=RuntimeError("URL included private-token")):
                with self.assertRaises(RuntimeError) as error:
                    client.call("minitoo-status")
                self.assertNotIn("private-token", str(error.exception))


if __name__ == "__main__":
    unittest.main()
