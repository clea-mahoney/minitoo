"""Firebase REST access with explicit login modes and renewable tokens."""
import json
import os
import time
import urllib.parse
import urllib.request


def request(url, data=None, method="GET"):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read())


def request_form(url, data):
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read())


class Firebase:
    def __init__(self):
        self.mode = os.environ.get("FIREBASE_AUTH_MODE", "password")
        if self.mode not in ("password", "anonymous"):
            raise ValueError("FIREBASE_AUTH_MODE must be password or anonymous")
        names = ("FIREBASE_DB_URL", "FIREBASE_API_KEY")
        if self.mode == "password":
            names += ("FIREBASE_EMAIL", "FIREBASE_PASSWORD")
        if any(not os.environ.get(name) for name in names):
            raise ValueError("Missing Firebase settings for the selected login mode")
        self.base = os.environ["FIREBASE_DB_URL"].rstrip("/")
        if urllib.parse.urlparse(self.base).scheme != "https":
            raise ValueError("Use an HTTPS Firebase database URL")
        self.token = ""
        self.refresh_token = ""
        self.expires = 0

    def auth(self):
        if time.monotonic() < self.expires:
            return self.token
        key = urllib.parse.quote(os.environ["FIREBASE_API_KEY"], safe="")
        if self.refresh_token:
            response = request_form(f"https://securetoken.googleapis.com/v1/token?key={key}", {
                "grant_type": "refresh_token", "refresh_token": self.refresh_token})
            self.token = response["id_token"]
            self.refresh_token = response["refresh_token"]
            expiry = response["expires_in"]
        else:
            endpoint = "signUp" if self.mode == "anonymous" else "signInWithPassword"
            credentials = {"returnSecureToken": True}
            if self.mode == "password":
                credentials.update(email=os.environ["FIREBASE_EMAIL"], password=os.environ["FIREBASE_PASSWORD"])
            response = request(f"https://identitytoolkit.googleapis.com/v1/accounts:{endpoint}?key={key}", credentials, "POST")
            self.token = response["idToken"]
            self.refresh_token = response["refreshToken"]
            expiry = response["expiresIn"]
        self.expires = time.monotonic() + max(0, int(expiry) - 60)
        return self.token

    def call(self, path, data=None, method="GET"):
        token = urllib.parse.quote(self.auth(), safe="")
        try:
            return request(f"{self.base}/{path}.json?auth={token}", data, method)
        except Exception:
            raise RuntimeError("Firebase request failed. Check local credentials and database rules.") from None
