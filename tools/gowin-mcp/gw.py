#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gowin 工具链 CLI——给 pi 等不支持 MCP 的 agent 用（与 server.py 同一套逻辑）。

用法：
  py gw.py info                          工具链路径 + 可用 Tcl 命令
  py gw.py tcl "<tcl 脚本>"              在 gw_sh 里执行 Tcl（也可 --file x.tcl）
  py gw.py build <工程.gprj>             open_project → run syn → run pnr
  py gw.py program -- <programmer 参数>  调 programmer_cli.exe
通用选项：--cwd <目录>  --timeout <秒>（默认 900）
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import (  # noqa: E402
    GOWIN_TCL_COMMANDS,
    PROGRAMMER_CLI,
    GW_SH,
    run_process,
)


def main():
    ap = argparse.ArgumentParser(description="Gowin EDA CLI (gw_sh / programmer_cli)")
    ap.add_argument("--cwd", default=None, help="工作目录")
    ap.add_argument("--timeout", type=float, default=900)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info")

    p_tcl = sub.add_parser("tcl", help="在 gw_sh 执行 Tcl")
    p_tcl.add_argument("script", nargs="?", default=None, help="Tcl 脚本正文")
    p_tcl.add_argument("--file", default=None, help="从文件读 Tcl")

    p_build = sub.add_parser("build", help="构建 .gprj 工程")
    p_build.add_argument("project", help=".gprj 文件路径")

    p_prog = sub.add_parser("program", help="调 programmer_cli.exe")
    p_prog.add_argument("pargs", nargs="*", default=[])

    args = ap.parse_args()
    cwd = os.path.abspath(args.cwd) if args.cwd else os.getcwd()

    if args.cmd == "info":
        print("\n".join([
            "GOWIN_ROOT = %s" % os.environ.get(
                "GOWIN_ROOT", r"E:\FBGA\Gowin\Gowin_V1.9.10.02_x64"),
            "gw_sh      = %s (存在: %s)" % (GW_SH, os.path.isfile(GW_SH)),
            "programmer = %s (存在: %s)" % (PROGRAMMER_CLI, os.path.isfile(PROGRAMMER_CLI)),
            "Gowin 专属 Tcl 命令: " + " ".join(GOWIN_TCL_COMMANDS),
            "已实测构建序列: open_project <gprj> → run syn → run pnr（pnr 自动出比特流 .fs）",
        ]))
        return 0

    if args.cmd == "tcl":
        script = open(args.file, encoding="utf-8").read() if args.file else args.script
        if not script:
            ap.error("tcl 需要 <脚本正文> 或 --file <文件>")
        with tempfile_dir() as tmp:
            tcl_path = os.path.join(tmp, "cli_cmd.tcl")
            with open(tcl_path, "w", encoding="utf-8") as f:
                f.write(script)
            rc, out, timed_out = run_process(
                [GW_SH, tcl_path], cwd=cwd, timeout_s=args.timeout)
        print(out)
        if timed_out:
            print("[TIMED OUT]", file=sys.stderr)
        return rc if not timed_out else 124

    if args.cmd == "build":
        project = os.path.abspath(args.project)
        if not project.lower().endswith(".gprj") or not os.path.isfile(project):
            print("project 必须是已存在的 .gprj 文件: %s" % project, file=sys.stderr)
            return 2
        with tempfile_dir() as tmp:
            tcl_path = os.path.join(tmp, "cli_build.tcl")
            with open(tcl_path, "w", encoding="utf-8") as f:
                f.write("open_project {%s}\nrun syn\nrun pnr\n" % project)
            rc, out, timed_out = run_process(
                [GW_SH, tcl_path], cwd=os.path.dirname(project), timeout_s=args.timeout)
        print(out)
        print("== 产物目录: %s\\impl\\pnr ==" % os.path.dirname(project))
        return rc if not timed_out else 124

    if args.cmd == "program":
        rc, out, timed_out = run_process(
            [PROGRAMMER_CLI] + args.pargs, timeout_s=args.timeout)
        print(out)
        return rc if not timed_out else 124

    return 2


class tempfile_dir:
    """contextlib.tempfile.TemporaryDirectory 的轻量别名（避免多余 import 分散）。"""

    def __enter__(self):
        import tempfile
        self._td = tempfile.TemporaryDirectory(prefix="gowin_cli_")
        return self._td.name

    def __exit__(self, *exc):
        self._td.cleanup()
        return False


if __name__ == "__main__":
    sys.exit(main())
