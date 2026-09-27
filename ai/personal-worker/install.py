#!/usr/bin/env python3
"""安裝已建好的個人工作程式；憑證由私有設定檔讀取，絕不輸出。"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
home = Path.home()
target = home / "Library/Application Support/BearTravelAI"
target.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(target, 0o700)
config_path = target / "config.json"
if not config_path.exists():
    sys.exit("請先建立權限 600 的個人 AI config.json；欄位與設定方式見 README。")
os.chmod(config_path, 0o600)
config = json.loads(config_path.read_text())
node = shutil.which("node")
if not node or int(subprocess.check_output([node, "-p", "process.versions.node.split('.')[0]"], text=True)) < 22:
    sys.exit("需要 Node.js 22 以上。")
if not config.get("endpoint", "").startswith("https://") or not config.get("token"):
    sys.exit("設定缺少雲端工作入口或個人憑證。")
shutil.copy2(root / "build/personal-ai/worker.mjs", target / "worker.mjs")
os.chmod(target / "worker.mjs", 0o600)
label = "com.jordan9185.beartravel.personal-ai"
agent_path = home / "Library/LaunchAgents" / (label + ".plist")
agent_path.parent.mkdir(parents=True, exist_ok=True)
plist = {
    "Label": label,
    "ProgramArguments": [node, str(target / "worker.mjs"), str(config_path)],
    "WorkingDirectory": str(target),
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 30,
    "EnvironmentVariables": {"PATH": str(Path(node).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home)},
    "StandardOutPath": str(target / "worker.log"),
    "StandardErrorPath": str(target / "worker-error.log"),
    "ProcessType": "Background",
}
agent_path.write_bytes(plistlib.dumps(plist))
os.chmod(agent_path, 0o600)
domain = "gui/" + str(os.getuid())
subprocess.run(["launchctl", "bootout", domain + "/" + label], capture_output=True)
# bootout 回傳時，舊服務可能仍在清理；等待後再載入，避免更新後背景程式消失。
for attempt in range(10):
    started = subprocess.run(["launchctl", "bootstrap", domain, str(agent_path)], capture_output=True, text=True)
    if started.returncode == 0:
        break
    time.sleep(1)
else:
    sys.exit("背景程式未能啟動；請用 launchctl 檢查安裝狀態後重新安裝。")
print("個人 GPT 工作程式已安裝，登入 Mac 後自動啟動。沒有更改睡眠設定。")
