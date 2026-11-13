#!/usr/bin/env python3
"""Drive `LiteMux --mcp` the way a coding agent does and check the answers.

    scripts/bridge-smoke.py <path to LiteMux executable> <host> [--confirm-shot out.png]

Plain mode runs every tool against <host> (which needs a LiteMux tmux pane
lm_1 printing a training log) and exits non-zero on the first wrong answer.
It switches ~/.config/litemux/bridge.json between modes as it goes.
--confirm-shot instead asks for one command in "confirm" mode, screenshots
the LiteMux dialog and dismisses it with Escape.
"""
import filecmp, json, os, queue, shutil, subprocess, sys, tempfile, threading, time

CONFIG = os.path.expanduser("~/.config/litemux/bridge.json")


def set_mode(mode):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump({"mode": mode}, f)


class Bridge:
    def __init__(self, exe):
        self.p = subprocess.Popen([exe, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=sys.stderr, text=True, bufsize=1)
        self.q = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            line = line.strip()
            if line:
                self.q.put(json.loads(line))

    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.next_id += 1
            msg["id"] = self.next_id
        self.p.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return msg.get("id")

    def wait(self, rid, timeout=45):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if m.get("id") == rid:
                return m
        raise SystemExit(f"no answer to request {rid} within {timeout}s")

    def rpc(self, method, params=None, timeout=45):
        return self.wait(self.send(method, params), timeout)

    def tool(self, name, **args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        if "error" in r:
            raise SystemExit(f"{name}: protocol error {r['error']}")
        res = r["result"]
        text = "\n".join(c.get("text", "") for c in res["content"])
        print(f"\n>>> {name} {json.dumps(args, ensure_ascii=False)}{'  [isError]' if res.get('isError') else ''}\n{text}")
        return text, res.get("isError", False)

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def expect(cond, what):
    if not cond:
        raise SystemExit(f"FAILED: {what}")
    print(f"    ok: {what}")


def full(exe, host):
    set_mode("trusted")
    b = Bridge(exe)
    init = b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "claude-code", "version": "smoke"}})
    print(">>> initialize\n" + json.dumps(init["result"], ensure_ascii=False, indent=2)[:600])
    expect(init["result"]["serverInfo"]["name"] == "litemux", "server introduces itself")
    b.send("notifications/initialized", notify=True)

    names = [t["name"] for t in b.rpc("tools/list")["result"]["tools"]]
    print(">>> tools/list\n    " + ", ".join(names))
    expect("run_command" in names and "training_status" in names, "all tools listed in trusted mode")
    expect({"host_status", "edit_file", "download_file", "upload_file"} <= set(names) and "gpu_status" not in names,
           "v0.3 tools listed, gpu_status only as an alias")

    text, err = b.tool("list_hosts")
    expect(not err and host in text and "lm_1" in text, "list_hosts sees the host and its lm_1 pane")

    text, err = b.tool("read_terminal", host=host, session="lm_1", lines=25)
    expect(not err and "Epoch" in text, "read_terminal returns the training log")

    text, err = b.tool("training_status", host=host, session="1")
    expect(not err and "状态" in text and "loss" in text, "training_status recognises the run")

    text, err = b.tool("gpu_status", host=host)
    expect(not err and "负载" in text, "gpu_status (alias) reports load (no GPU on CI)")

    web = subprocess.Popen([sys.executable, "-m", "http.server", "6006", "--bind", "127.0.0.1"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=os.path.expanduser("~/exp"))
    time.sleep(1.5)
    text, err = b.tool("host_status", host=host)
    expect(not err and "负载" in text and "磁盘" in text, "host_status reports load and mounts")
    expect("6006" in text and "监听端口" in text, "host_status lists the listening port 6006")
    web.kill()

    with open(os.path.expanduser("~/exp/train.log"), "w") as f:
        f.write("starting\n")
        for i in range(1, 13):
            f.write(f"Epoch {i:2d}/30  loss={2.0/i:.4f}  acc={1-1.0/(i+1):.4f}  lr=3.0e-04\n")
            f.write(f"\r  {i}/30 [=====>    ] it/s 9.1\r")
    text, err = b.tool("training_status", host=host, log_path="~/exp/train.log")
    expect(not err and "epoch 12/30" in text and "loss" in text, "training_status reads a log file (log_path)")

    text, err = b.tool("list_directory", host=host, path="~/exp")
    expect(not err and "config.yaml" in text, "list_directory")

    text, err = b.tool("read_file", host=host, path="~/exp/config.yaml")
    expect(not err and "vit_b16" in text, "read_file")

    text, err = b.tool("read_file", host=host, path="~/exp/config.yaml", start_line=2, end_line=3)
    expect(not err and "batch_size" in text and "lr: 3e-4" in text and "seed" not in text and "第 2–3 行（共 6 行）" in text,
           "read_file returns a line range")

    text, err = b.tool("read_file", host=host, path="~/exp/mask_0001.png")
    expect(err and "二进制" in text, "read_file refuses a PNG")

    text, err = b.tool("run_command", host=host, command="echo hello-from-agent; uname -s", cwd="~/exp")
    expect(not err and "hello-from-agent" in text and "退出码 0" in text, "run_command")

    text, err = b.tool("run_command", host=host, command="exit 7")
    expect(err and "退出码 7" in text, "run_command reports a failing exit code")

    text, err = b.tool("write_file", host=host, path="~/agent-scratch/notes/agent.txt", content="written by an agent\n")
    expect(not err, "write_file creates parent directories")
    text, err = b.tool("read_file", host=host, path="~/agent-scratch/notes/agent.txt")
    expect("written by an agent" in text, "the written file reads back")

    # edit_file: unique match, in place (mode stays), helpful refusals.
    script = os.path.expanduser("~/agent-scratch/edit_me.sh")
    with open(script, "w") as f:
        f.write("#!/bin/sh\nlr=0.1\nepochs=10\nlr=0.1\necho done\n")
    os.chmod(script, 0o755)
    text, err = b.tool("edit_file", host=host, path="~/agent-scratch/edit_me.sh", old_text="epochs=10", new_text="epochs=20")
    expect(not err and "1 处" in text and "- epochs=10" in text and "+ epochs=20" in text, "edit_file replaces a unique match and shows a diff")
    expect(open(script).read() == "#!/bin/sh\nlr=0.1\nepochs=20\nlr=0.1\necho done\n", "edit_file wrote exactly the change")
    expect(os.stat(script).st_mode & 0o777 == 0o755, "edit_file kept the file mode")
    expect(not os.path.exists(script + ".lm-edit"), "edit_file left no staging file")
    text, err = b.tool("edit_file", host=host, path="~/agent-scratch/edit_me.sh", old_text="lr=0.1", new_text="lr=0.2")
    expect(err and "2 次" in text, "edit_file refuses an ambiguous match")
    text, err = b.tool("edit_file", host=host, path="~/agent-scratch/edit_me.sh", old_text="nope", new_text="x")
    expect(err and "找不到" in text, "edit_file reports a missing match")

    # Transfers, byte for byte (host and agent share this machine on CI).
    local = tempfile.mkdtemp(prefix="lm-transfer-")
    text, err = b.tool("download_file", host=host, path="~/exp/mask_0001.png", local_path=local)
    got = os.path.join(local, "mask_0001.png")
    expect(not err and os.path.exists(got) and filecmp.cmp(got, os.path.expanduser("~/exp/mask_0001.png"), shallow=False),
           "download_file copies a binary file exactly")
    text, err = b.tool("download_file", host=host, path="~/exp/mask_0001.png", local_path=local)
    expect(err and "overwrite" in text, "download_file will not overwrite without asking")
    text, err = b.tool("download_file", host=host, path="~/exp", local_path=os.path.join(local, "exp-copy"))
    expect(not err and filecmp.cmp(os.path.join(local, "exp-copy", "config.yaml"), os.path.expanduser("~/exp/config.yaml"), shallow=False),
           "download_file brings a folder over as one tar stream")
    blob = os.path.join(local, "blob.bin")
    with open(blob, "wb") as f:
        f.write(os.urandom(300_000) + b"\x00\r\n\x00")
    text, err = b.tool("upload_file", host=host, local_path=blob, path="~/agent-scratch/up/")
    up = os.path.expanduser("~/agent-scratch/up/blob.bin")
    expect(not err and os.path.exists(up) and filecmp.cmp(up, blob, shallow=False), "upload_file copies a binary file exactly")
    text, err = b.tool("upload_file", host=host, local_path=os.path.join(local, "exp-copy"), path="~/agent-scratch/exp-up")
    expect(not err and os.path.exists(os.path.expanduser("~/agent-scratch/exp-up/mask_0001.png")), "upload_file sends a folder")
    shutil.rmtree(local, ignore_errors=True)

    text, err = b.tool("send_to_terminal", host=host, session="lm_2", text="echo typed-by-agent", wait_seconds=1.5)
    expect(not err and "typed-by-agent" in text, "send_to_terminal types into a pane and reads it back")

    tmux = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
    subprocess.run([tmux, "kill-session", "-t", "train"], stderr=subprocess.DEVNULL)
    subprocess.run([tmux, "new-session", "-d", "-s", "train", "python3 -c 'import time; print(\"busy job\"); time.sleep(900)'"], check=True)
    time.sleep(1)
    text, err = b.tool("read_terminal", host=host, session="train", lines=10)
    expect(not err and "busy job" in text, "read_terminal reads a session the user named themselves")
    text, err = b.tool("send_to_terminal", host=host, session="train", text="rm -rf /tmp/whatever")
    expect(err and "没有发送" in text and "session:\"new\"" in text, "send_to_terminal refuses to type into a busy program")
    text, err = b.tool("send_to_terminal", host=host, session="new", cwd="~/exp", text="echo from-new-pane; pwd", wait_seconds=2)
    expect(not err and "from-new-pane" in text and "新窗格 tmux lm_" in text, "send_to_terminal opens a fresh lm_ pane")
    new_session = text.split("新窗格 tmux ")[1].split("（")[0].split("。")[0].strip()
    expect(new_session not in ("lm_1", "lm_2"), f"the new pane ({new_session}) avoids lab1 slots open in LiteMux")
    subprocess.run([tmux, "kill-session", "-t", new_session], stderr=subprocess.DEVNULL)

    text, err = b.tool("read_terminal", host="no-such-host")
    expect(err and "list_hosts" in text, "unknown hosts get a helpful error")

    set_mode("readOnly")
    names = [t["name"] for t in b.rpc("tools/list")["result"]["tools"]]
    expect("run_command" not in names and "read_terminal" in names, "read-only mode hides acting tools")
    expect("edit_file" not in names and "upload_file" not in names and "download_file" in names,
           "read-only mode hides edits and uploads, keeps downloads")
    text, err = b.tool("run_command", host=host, command="touch ~/should-not-exist")
    expect(err and "只读" in text, "read-only mode refuses commands")
    expect(not os.path.exists(os.path.expanduser("~/should-not-exist")), "…and nothing ran")

    b.close()
    set_mode("confirm")
    print("\nBRIDGE SMOKE PASSED")


def confirm_shot(exe, host, png):
    set_mode("confirm")
    os.environ["LITEMUX_SMOKE_BRIDGE"] = "1"
    b = Bridge(exe)
    b.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                         "clientInfo": {"name": "codex-mcp-client", "version": "smoke"}})
    b.send("notifications/initialized", notify=True)
    rid = b.send("tools/call", {"name": "run_command", "arguments": {
        "host": host, "command": "nvidia-smi --gpu-reset -i 0", "cwd": "~/exp"}})
    time.sleep(5)
    subprocess.run(["screencapture", "-x", png])
    print("screenshot taken; pressing Escape")
    subprocess.run(["osascript", "-e", 'tell application "System Events" to key code 53'])
    try:
        r = b.wait(rid, timeout=8)
        print(json.dumps(r, ensure_ascii=False))
    except SystemExit as e:
        print(f"dialog not dismissed by Escape ({e}); killing")
    b.p.kill()


if __name__ == "__main__":
    exe, host = sys.argv[1], sys.argv[2]
    if len(sys.argv) > 4 and sys.argv[3] == "--confirm-shot":
        confirm_shot(exe, host, sys.argv[4])
    else:
        full(exe, host)
