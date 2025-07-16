import subprocess
import time
import datetime
from pathlib import Path


def prompt() -> str | None:
    script = (
        'text returned of (display dialog "What are you doing?" '
        'default answer "" with title "What are you doing?" '
        'buttons {"OK"} default button 1)'
    )
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def write(entry: str) -> None:
    today = datetime.date.today().strftime("%Y-%m-%d")
    ts = datetime.datetime.now().strftime("%H:%M")
    log = Path(__file__).with_name("log.md")
    h = f"## {today}\n"
    if log.exists():
        text = log.read_text(encoding="utf-8")
    else:
        text = ""
    with log.open("a", encoding="utf-8") as f:
        if h not in text:
            f.write(f"\n{h}")
        f.write(f"- {ts} {entry}\n")


def main() -> None:
    while True:
        ans = prompt()
        if ans:
            write(ans)
        time.sleep(1800)


if __name__ == "__main__":
    main() 