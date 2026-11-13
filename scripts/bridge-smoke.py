#!/usr/bin/env python3
"""Drive `LiteMux --mcp` the way a coding agent does and check the answers.

    scripts/bridge-smoke.py <path to LiteMux executable> <host> [--confirm-shot out.png]

Plain mode runs every tool against <host> (which needs a LiteMux tmux pane
lm_1 printing a training log) and exits non-zero on the first wrong answer.
It switches ~/.config/litemux/bridge.json between modes as it goes.
--confirm-shot instead asks for one command in "confirm" mode, screenshots
the LiteMux dialog and dismisses it with Escape.
"""
import json, os, queue, subprocess, sys, threading, time

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

    text, err = b.tool("list_hosts")
    expect(not err and host in text and "lm_1" in text, "list_hosts sees the host and its lm_1 pane")

    text, err = b.tool("read_terminal", host=host, session="lm_1", lines=25)
    expect(not err and "Epoch" in text, "read_terminal returns the training log")

    text, err = b.tool("training_status", host=host, session="1")
    expect(not err and "状态" in text and "loss" in text, "training_status recognises the run")

    text, err = b.tool("gpu_status", host=host)
    expect(not err and "负载" in text, "gpu_status reports load (no GPU on CI)")

    text, err = b.tool("list_directory", host=host, path="~/exp")
    expect(not err and "config.yaml" in text, "list_directory")

    text, err = b.tool("read_file", host=host, path="~/exp/config.yaml")
    expect(not err and "vit_b16" in text, "read_file")

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

    text, err = b.tool("send_to_terminal", host=host, session="lm_2", text="echo typed-by-agent", wait_seconds=1.5)
    expect(not err and "typed-by-agent" in text, "send_to_terminal types into a pane and reads it back")

    text, err = b.tool("read_terminal", host="no-such-host")
    expect(err and "list_hosts" in text, "unknown hosts get a helpful error")

    set_mode("readOnly")
    names = [t["name"] for t in b.rpc("tools/list")["result"]["tools"]]
    expect("run_command" not in names and "read_terminal" in names, "read-only mode hides acting tools")
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
