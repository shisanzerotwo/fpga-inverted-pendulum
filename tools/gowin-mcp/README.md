# gowin-mcp — 高云 Gowin EDA 的 MCP server / CLI

两套入口，同一套逻辑：

- **MCP server**（`server.py`）：给 ZCode 等支持 MCP 的客户端用，4 个工具见下表。
- **CLI**（`gw.py`）：给 pi 等不支持 MCP 的 agent 用（pi 官方设计即"CLI + Skill"），
  子命令 `info / tcl / build / program`，已注册 pi skill `~/.pi/agent/skills/gowin/`。

把本机 Gowin 工具链封装起来，让 agent 直接驱动 FPGA 构建流程。
零第三方依赖，纯 Python 标准库（stdio JSON-RPC），用 `py` 启动器运行。

## 工具（MCP 侧）

| 工具 | 作用 |
|---|---|
| `gw_run_tcl` | 在 gw_sh（Gowin Tcl 控制台）执行任意 Tcl，返回完整输出 |
| `gw_build`   | `open_project .gprj → run syn → run pnr`，返回构建日志（实测 `run pnr` 会自动生成比特流 `.fs`） |
| `gw_program` | 调 `programmer_cli.exe` 下载/擦除等 |
| `gw_info`    | 工具链路径 + Gowin Tcl 命令清单 |

## 工具链路径

默认读 `GOWIN_ROOT` 环境变量（`.mcp.json` 里已配 `E:\FBGA\Gowin\Gowin_V1.9.10.02_x64`），
未设置时用同一默认值。

## 实测记录（2026-10-01）

- gw_sh 无头执行 Tcl 脚本可用；license 提示（"expires in 11 days"）是浮动刷新周期，不是过期。
- 通过本 server 真实构建了 `inverted-pendulum/fpga/test_env`（综合 + 布线 + 比特流，3.9s），
  产物 `impl/pnr/test_env.fs` 确认生成。
- Gowin 专属 Tcl 命令用 `info commands` 实测枚举：`open_project / create_project / add_file /
  set_option / set_device / run / saveto / set_csr / set_file_prop / set_file_enable /
  reset_option / rm_file / import_files / set_synplify_path`。

## 接入

项目根目录 `.mcp.json` 已注册（server 名 `gowin`）。新会话启动时按客户端提示批准即可；
未生效就重启 ZCode。手动验证：

```bash
cd tools/gowin-mcp
py -c "import json;print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'gw_info','arguments':{}}}))" | py server.py
```

## 注意

- `gw_run_tcl` 是任意命令执行入口（等价于把 gw_sh 交给 agent），仅在本机开发环境使用。
- 超时会 `taskkill /T /F` 整树击杀，防止 GowinSynthesis 等子进程残留。
- 输出编码自动在 utf-8/gbk 间择优解码，中文日志不会乱码。
