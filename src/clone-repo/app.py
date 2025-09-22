import os
import socket
import subprocess
import time
import shutil
from collections import deque
from urllib.parse import urlparse, urlunparse, quote
from flask import Flask, render_template, request, jsonify

app = Flask(__name__, template_folder="templates")

TARGET_DIR = "/home/coder/documentation-dev"
HUGO_PORT = 1313
HUGO_LOG = "/home/coder/hugo-server.log"
BASE_URL = "http://preview.localhost/"

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

def is_port_open(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        try:
            s.connect((host, port))
            return True
        except Exception:
            return False

def tail_file(path: str, n: int = 200) -> str:
    if not os.path.isfile(path):
        return ""
    dq = deque(maxlen=n)
    with open(path, "r", errors="replace") as f:
        for line in f:
            dq.append(line.rstrip("\n"))
    return "\n".join(dq)

def prepare_hugo_modules():
    """Clean and resolve Hugo modules before server start."""
    cache_dir = os.path.expanduser("~/.cache/hugo_cache")
    try:
        if os.path.isdir(cache_dir):
            shutil.rmtree(cache_dir, ignore_errors=True)
    except Exception:
        pass
    subprocess.run(["hugo", "mod", "tidy"], cwd=TARGET_DIR, check=False, capture_output=True, text=True, timeout=120)
    subprocess.run(["hugo", "mod", "graph"], cwd=TARGET_DIR, check=False, capture_output=True, text=True, timeout=120)

@app.get("/")
def index():
    return render_template("index.html")

@app.post("/clone")
def clone_repo():
    data = request.get_json(silent=True) or {}
    repo_url = (data.get("repo_url") or "").strip()
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "").strip()
    email    = (data.get("email")    or "").strip()

    if not repo_url:
        return jsonify({"ok": False, "error": "Repository URL is required"}), 400
    if not username or not password:
        return jsonify({"ok": False, "error": "Username and password are required"}), 400
    if not email:
        return jsonify({"ok": False, "error": "Email is required"}), 400

    try:
        ensure_clean_target(TARGET_DIR)

        # Klonen mit temporär eingebetteten Credentials
        auth_url = build_auth_url(repo_url, username, password)
        proc = subprocess.run(
            ["git", "clone", auth_url, TARGET_DIR],
            capture_output=True, text=True, timeout=900
        )
        if proc.returncode != 0:
            return jsonify({"ok": False, "error": "git clone failed", "stderr": proc.stderr}), 400

        # Remote-URL sofort auf credential-freie URL zurücksetzen (keine Secrets in .git/config)
        subprocess.run(["git", "-C", TARGET_DIR, "remote", "set-url", "origin", repo_url],
                       capture_output=True, text=True, timeout=30)

        # user.name / user.email auf Repo-Ebene setzen (lokal)
        set_name  = subprocess.run(["git", "-C", TARGET_DIR, "config", "user.name", username],
                                   capture_output=True, text=True, timeout=20)
        set_email = subprocess.run(["git", "-C", TARGET_DIR, "config", "user.email", email],
                                   capture_output=True, text=True, timeout=20)
        if set_name.returncode != 0 or set_email.returncode != 0:
            return jsonify({
                "ok": False,
                "error": "Failed to configure git user.name or user.email",
                "stderr_name": set_name.stderr,
                "stderr_email": set_email.stderr
            }), 400

        # origin/HEAD korrekt setzen und Refs synchronisieren
        subprocess.run(["git", "-C", TARGET_DIR, "remote", "set-head", "origin", "-a"],
                       capture_output=True, text=True, timeout=30)
        subprocess.run(["git", "-C", TARGET_DIR, "fetch", "origin", "--prune"],
                       capture_output=True, text=True, timeout=120)

        return jsonify({"ok": True, "message": "Repository cloned and git user configured"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400

@app.get("/status")
def status():
    info = {
        "target_exists": os.path.isdir(TARGET_DIR),
        "marker_exists": os.path.isfile(os.path.join(TARGET_DIR, "hugo.yaml")),
        "port_1313_open": is_port_open("127.0.0.1", HUGO_PORT),
        "hugo_path": shutil.which("hugo"),
        "hugo_version": None,
        "target_listing": None,
        "log_path": HUGO_LOG,
        "log_tail": tail_file(HUGO_LOG, 50)
    }
    try:
        out = subprocess.run(["hugo", "version"], capture_output=True, text=True, timeout=10)
        info["hugo_version"] = out.stdout.strip() or out.stderr.strip()
    except Exception as e:
        info["hugo_version"] = f"error: {e}"
    try:
        if os.path.isdir(TARGET_DIR):
            info["target_listing"] = "\n".join(sorted(os.listdir(TARGET_DIR))[:200])
    except Exception as e:
        info["target_listing"] = f"error: {e}"
    return jsonify({"ok": True, "status": info})

@app.get("/logs")
def logs():
    tail = request.args.get("tail", "200")
    try:
        n = max(1, min(5000, int(tail)))
    except Exception:
        n = 200
    content = tail_file(HUGO_LOG, n)
    if not content:
        return jsonify({"ok": False, "error": "Log file not found or empty", "path": HUGO_LOG}), 404
    return jsonify({"ok": True, "path": HUGO_LOG, "lines": n, "log": content})

@app.post("/start-preview")
def start_preview():
    debug = {
        "target_dir": TARGET_DIR,
        "marker": os.path.join(TARGET_DIR, "hugo.yaml"),
    }
    try:
        if not os.path.isfile(debug["marker"]):
            return jsonify({"ok": False, "error": "No cloned repository detected", "debug": debug}), 400

        if is_port_open("127.0.0.1", HUGO_PORT):
            return jsonify({"ok": True, "message": "Hugo preview already running"})

        prepare_hugo_modules()

        os.makedirs(os.path.dirname(HUGO_LOG), exist_ok=True)
        with open(HUGO_LOG, "a") as logf:
            subprocess.Popen(
                ["hugo", "server", "-D", "--bind", "0.0.0.0", "--port", str(HUGO_PORT), "--baseURL", BASE_URL],
                cwd=TARGET_DIR,
                stdout=logf,
                stderr=logf,
                preexec_fn=os.setsid
            )

        for _ in range(20):  # ~10s
            time.sleep(0.5)
            if is_port_open("127.0.0.1", HUGO_PORT):
                return jsonify({"ok": True, "message": "Hugo preview started"})
        return jsonify({"ok": False, "error": "Failed to start Hugo preview", "log_tail": tail_file(HUGO_LOG, 200)}), 500
    except Exception as e:
        return jsonify({"ok": False, "error": str(e), "log_tail": tail_file(HUGO_LOG, 200)}), 500
