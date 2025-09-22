import os
import subprocess
from urllib.parse import urlparse, urlunparse, quote
from flask import Flask, render_template, request, jsonify

app = Flask(__name__, template_folder="templates")

TARGET_DIR = "/home/coder/documentation-dev"

def build_auth_url(repo_url: str, username: str, password: str) -> str:
    parsed = urlparse(repo_url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("Only http(s) repository URLs are supported")
    user_enc = quote(username, safe="")
    pass_enc = quote(password, safe="")
    netloc_no_userinfo = parsed.netloc.split("@", 1)[-1] if "@" in parsed.netloc else parsed.netloc
    netloc_with_auth = f"{user_enc}:{pass_enc}@{netloc_no_userinfo}"
    return urlunparse(parsed._replace(netloc=netloc_with_auth))

def ensure_clean_target(target_dir: str):
    if not os.path.exists(target_dir):
        os.makedirs(target_dir, exist_ok=True); return
    if os.path.isdir(target_dir) and not os.listdir(target_dir):
        return
    raise RuntimeError(f"Target directory '{target_dir}' is not empty")

@app.get("/")
def index():
    return render_template("index.html")

@app.post("/clone")
def clone_repo():
    data = request.get_json(silent=True) or {}
    repo_url = (data.get("repo_url") or "").strip()
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    if not repo_url:
        return jsonify({"ok": False, "error": "Repository URL is required"}), 400
    if not username or not password:
        return jsonify({"ok": False, "error": "Username and password are required"}), 400

    try:
        ensure_clean_target(TARGET_DIR)
        auth_url = build_auth_url(repo_url, username, password)
        cmd = ["git", "clone", "--depth", "1", auth_url, TARGET_DIR]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            return jsonify({"ok": False, "error": "git clone failed", "stderr": proc.stderr}), 400
        return jsonify({"ok": True, "message": "Repository cloned successfully"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400
