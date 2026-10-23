"""Run the current RTL benches and Gowin build; retain raw evidence."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
IV = ROOT.parent / 'iverilog/bin/iverilog.exe'
VVP = IV.with_name('vvp.exe')
GOWIN = Path('D:/Gowin/Gowin_V1.9.10.02_x64/IDE/bin/gw_sh.exe')
rtl = sorted((ROOT / 'fpga_project/src').glob('*.v'))
before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in rtl + [ROOT / 'fpga_project/fpga_project.gprj']}
results = []
started = time.monotonic()
build_log = (OUT / 'gowin_build.log').open('w', encoding='utf-8')
build_cmd = [str(GOWIN), str(ROOT / '_tools/gw_build.tcl')]
build = subprocess.Popen(build_cmd, cwd=ROOT, stdout=build_log,
                         stderr=subprocess.STDOUT)
print('GOWIN STARTED', build.pid, flush=True)
try:
    for tb in sorted((ROOT / 'fpga_project/sim').glob('*_tb.v')):
        dest = OUT / 'sim' / tb.stem
        dest.mkdir(parents=True, exist_ok=True)
        executable = dest / (tb.stem + '.vvp')
        commands = [[str(IV), '-g2012', '-s', tb.stem, '-o', str(executable),
                     str(tb), *map(str, rtl)], [str(VVP), str(executable)]]
        entry = dict(name=tb.stem, commands=commands, passed=False)
        begin = time.monotonic()
        try:
            compile_run = subprocess.run(commands[0], cwd=dest, capture_output=True,
                                         timeout=60, encoding='gbk', errors='replace')
            (dest / 'compile.log').write_text(compile_run.stdout + compile_run.stderr,
                                               encoding='utf-8')
            entry['compile_exit'] = compile_run.returncode
            if compile_run.returncode == 0:
                run = subprocess.run(commands[1], cwd=dest, capture_output=True,
                                     timeout=90, encoding='gbk', errors='replace')
                output = run.stdout + run.stderr
                (dest / 'run.log').write_text(output, encoding='utf-8')
                entry.update(run_exit=run.returncode,
                    passed=run.returncode == 0 and bool(re.search(r'\bPASS\b', output))
                    and not bool(re.search(r'\b(?:FAIL|FATAL|ERROR)\b', output)),
                    pass_lines=[s for s in output.splitlines() if 'PASS' in s])
        except subprocess.TimeoutExpired as exc:
            entry['error'] = str(exc)
        entry['elapsed_s'] = round(time.monotonic() - begin, 3)
        results.append(entry)
        (OUT / 'sim_results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
        print(('PASS ' if entry['passed'] else 'FAIL ') + tb.stem,
              entry['elapsed_s'], flush=True)
    try:
        build_exit = build.wait(timeout=max(1, 360 - (time.monotonic() - started)))
    except subprocess.TimeoutExpired:
        build.kill()
        build_exit = build.wait()
finally:
    build_log.close()
after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in rtl + [ROOT / 'fpga_project/fpga_project.gprj']}
fs = ROOT / 'fpga_project/impl/pnr/fpga_project.fs'
log = (OUT / 'gowin_build.log').read_text(encoding='utf-8', errors='replace')
header = fs.read_bytes()[:1800].decode('ascii', 'replace') if fs.exists() else ''
usercode = re.search(r'UserCode:\s*(0x[0-9A-Fa-f]+)', header)
summary = dict(sim_passed=sum(r['passed'] for r in results), sim_total=len(results),
    build_command=build_cmd, build_exit=build_exit,
    bitstream_generated='Bitstream generation completed' in log,
    source_unchanged=before == after, source_hashes=after,
    bitstream_sha256=hashlib.sha256(fs.read_bytes()).hexdigest() if fs.exists() else None,
    usercode=usercode.group(1) if usercode else None,
    elapsed_s=round(time.monotonic() - started, 3))
(OUT / 'offline_results.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
print(json.dumps(summary, indent=2), flush=True)
raise SystemExit(0 if summary['sim_passed'] == summary['sim_total']
    and build_exit == 0 and summary['bitstream_generated']
    and summary['source_unchanged'] else 1)
