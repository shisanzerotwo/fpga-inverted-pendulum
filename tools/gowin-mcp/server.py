#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Gowin EDA MCP server (stdio, 零第三方依赖).

把本机 Gowin 工具链封装成 MCP 工具，让 agent 可以：
  - gw_run_tcl   : 在 gw_sh（Gowin Tcl 控制台）里执行任意 Tcl 脚本
  - gw_build     : 打开 .gprj 工程，跑综合 + 布局布线（run syn / run pnr）
  - gw_program   : 调 Gowin Programmer CLI（programmer_cli.exe）下载比特流
  - gw_info      : 查看工具链路径与 Gowin Tcl 命令清单

实测环境（2026-10-01）：Gowin IDE V1.9.10.02 @ E:\\FBGA，Python 3.14（py 启动器）。
gw_sh 已实测可无头执行 Tcl 脚本；已实测命令：create_project / add_file /
set_option / run syn / run pnr / open_project。
"""
import json
import os
import subprocess
import sys
import tempfile
import time

GOWIN_ROOT = os.environ.get(
    "GOWIN_ROOT", r"E:\FBGA\Gowin\Gowin_V1.9.10.02_x64"
)
GW_SH = os.path.join(GOWIN_ROOT, "IDE", "bin", "gw_sh.exe")
PROGRAMMER_CLI = os.path.join(GOWIN_ROOT, "Programmer", "bin", "programmer_cli.exe")

DEFAULT_TIMEOUT_S = 900

# 2026-10-01 用 `info commands` 从 gw_sh 实测枚举（114 个命令中的 Gowin 专属部分）
GOWIN_TCL_COMMANDS = [
    "add_file", "create_project", "import_files", "open_project",
    "reset_option", "rm_file", "run", "saveto", "set_csr", "set_device",
    "set_file_enable", "set_file_prop", "set_option", "set_synplify_path",
]

TOOLS = [
    {
        "name": "gw_run_tcl",
        "description": (
            "在 Gowin Tcl 控制台（gw_sh.exe）中执行一段 Tcl 脚本并返回完整输出。"
            "可用的 Gowin 专属命令：create_project / open_project / add_file / "
            "set_option / set_device / run syn / run pnr / saveto 等。"
            "标准 Tcl（puts/file/cd…）同样可用。适合做工程操作、参数修改等一次性操作。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "script": {"type": "string", "description": "Tcl 脚本正文（多行 OK）"},
                "cwd": {
                    "type": "string",
                    "description": "工作目录（相对路径以它解析）；默认用当前目录",
                },
                "timeout_s": {"type": "number", "description": "超时秒数，默认 900"},
            },
            "required": ["script"],
        },
    },
    {
        "name": "gw_build",
        "description": (
            "构建一个 Gowin 工程：open_project <gprj> → run syn → run pnr，"
            "返回完整构建日志与产物目录提示。传 .gprj 文件路径。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description": ".gprj 工程文件的绝对路径"},
                "timeout_s": {"type": "number", "description": "超时秒数，默认 900"},
            },
            "required": ["project"],
        },
    },
    {
        "name": "gw_program",
        "description": (
            "调用 Gowin Programmer CLI（programmer_cli.exe）。把要传的命令行参数放进 args 数组，"
            "例如 {\"args\": [\"--device\", \"GW2A-LV18PG256C8/I7\", \"--fsFile\", \"xxx.fs\"]}。"
            "用法不确定时先传 [\"--help\"] 看说明。操作前请确认板卡已接好。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "传给 programmer_cli.exe 的参数",
                },
                "timeout_s": {"type": "number", "description": "超时秒数，默认 900"},
            },
            "required": ["args"],
        },
    },
    {
        "name": "gw_info",
        "description": "返回 Gowin 工具链路径、可用 Tcl 命令清单等环境信息。",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def decode_best(raw: bytes) -> str:
    """Gowin 输出编码不固定（中文 Windows 下多为 GBK），先试 utf-8 再退 gbk。"""
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def run_process(cmd, cwd=None, timeout_s=DEFAULT_TIMEOUT_S):
    """跑子进程并整树超时击杀，返回 (returncode, 合并输出文本, 是否超时)。"""
    start = time.time()
    proc = subprocess.Popen(
        cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    timed_out = False
    try:
        raw, _ = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        timed_out = True
        subprocess.run(
            ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
            capture_output=True,
        )
        raw, _ = proc.communicate()
    out = decode_best(raw or b"")
    out += "\n[elapsed %.1fs]" % (time.time() - start)
    if timed_out:
        out += "\n[TIMED OUT after %ss — 进程树已强制结束]" % timeout_s
    return proc.returncode, out, timed_out


def tool_gw_run_tcl(args):
    script = args["script"]
    cwd = args.get("cwd") or os.getcwd()
    cwd = os.path.abspath(cwd)
    if not os.path.isdir(cwd):
        return err("cwd 不存在: %s" % cwd)
    timeout_s = float(args.get("timeout_s", DEFAULT_TIMEOUT_S))

    with tempfile.TemporaryDirectory(prefix="gowin_mcp_") as tmp:
        tcl_path = os.path.join(tmp, "mcp_cmd.tcl")
        with open(tcl_path, "w", encoding="utf-8") as f:
            f.write(script)
        # gw_sh 只在脚本里报错时返回非 0；输出统一捕获后原样返回
        rc, out, timed_out = run_process([GW_SH, tcl_path], cwd=cwd, timeout_s=timeout_s)
    header = "exit=%s cwd=%s" % (rc, cwd)
    return ok("%s\n%s" % (header, out))


def tool_gw_build(args):
    project = os.path.abspath(args["project"])
    if not project.lower().endswith(".gprj") or not os.path.isfile(project):
        return err("project 必须是已存在的 .gprj 文件路径: %s" % project)
    timeout_s = float(args.get("timeout_s", DEFAULT_TIMEOUT_S))

    script = "open_project {%s}\nrun syn\nrun pnr\n" % project
    with tempfile.TemporaryDirectory(prefix="gowin_mcp_") as tmp:
        tcl_path = os.path.join(tmp, "mcp_build.tcl")
        with open(tcl_path, "w", encoding="utf-8") as f:
            f.write(script)
        rc, out, timed_out = run_process(
            [GW_SH, tcl_path], cwd=os.path.dirname(project), timeout_s=timeout_s
        )
    tail = "\n".join(out.splitlines()[-40:])
    header = "exit=%s project=%s%s" % (rc, project, " [TIMED OUT]" if timed_out else "")
    return ok("%s\n--- 日志尾部 40 行 ---\n%s\n(完整日志见上方输出)" % (header, tail))


def tool_gw_program(args):
    cli_args = [str(a) for a in args.get("args", [])]
    timeout_s = float(args.get("timeout_s", DEFAULT_TIMEOUT_S))
    if not os.path.isfile(PROGRAMMER_CLI):
        return err("programmer_cli.exe 不存在: %s" % PROGRAMMER_CLI)
    rc, out, timed_out = run_process(
        [PROGRAMMER_CLI] + cli_args, timeout_s=timeout_s
    )
    return ok("exit=%s cmd=programmer_cli %s%s\n%s" % (
        rc, " ".join(cli_args), " [TIMED OUT]" if timed_out else "", out))


def tool_gw_info(_args):
    lines = [
        "GOWIN_ROOT = %s" % GOWIN_ROOT,
        "gw_sh      = %s (存在: %s)" % (GW_SH, os.path.isfile(GW_SH)),
        "programmer = %s (存在: %s)" % (PROGRAMMER_CLI, os.path.isfile(PROGRAMMER_CLI)),
        "",
        "Gowin 专属 Tcl 命令（2026-10-01 从 gw_sh info commands 实测枚举）：",
        "  " + "  ".join(GOWIN_TCL_COMMANDS),
        "",
        "已实测可用的构建序列：open_project <gprj> → run syn → run pnr",
        "（create_project -name X -dir D -pn <器件> -device_version C 也已实测）",
    ]
    return ok("\n".join(lines))


def ok(text):
    return {"content": [{"type": "text", "text": text}], "isError": False}


def err(text):
    return {"content": [{"type": "text", "text": text}], "isError": True}


TOOL_FUNCS = {
    "gw_run_tcl": tool_gw_run_tcl,
    "gw_build": tool_gw_build,
    "gw_program": tool_gw_program,
    "gw_info": tool_gw_info,
}


def handle(req):
    method = req.get("method")
    msg_id = req.get("id")
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": req.get("params", {}).get(
                    "protocolVersion", "2024-11-05"
                ),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "gowin-mcp", "version": "0.1.0"},
            },
        }
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = req["params"]["name"]
        func = TOOL_FUNCS.get(name)
        if func is None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "result": err("未知工具: %s" % name)}
        try:
            result = func(req["params"].get("arguments", {}))
        except Exception as exc:  # 工具内部异常也要以 MCP 结果形式返回
            result = err("%s: %s" % (type(exc).__name__, exc))
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if msg_id is not None:  # 未知请求型方法要回错误，通知型方法静默
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": "method not found: %s" % method}}
    return None


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
