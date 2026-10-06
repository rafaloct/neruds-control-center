from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
SERVICE_NAME = "NERUDS-Control-Bridge"
SERVICE_DISPLAY_NAME = "NERUDS Control Bridge"
SERVICE_DESCRIPTION = (
    "Bridge local do NERUDS Control Center. "
    "Expõe somente 127.0.0.1:8787 e é publicado pela tailnet via Tailscale Serve."
)


def default_python_executable() -> str:
    windows_venv_python = BRIDGE_DIR / ".venv" / "Scripts" / "python.exe"
    if windows_venv_python.is_file():
        return str(windows_venv_python)
    return sys.executable


def uvicorn_command(python_executable: str | None = None) -> list[str]:
    python = python_executable or default_python_executable()
    return [
        python,
        "-m",
        "uvicorn",
        "main:app",
        "--host",
        "127.0.0.1",
        "--port",
        "8787",
        "--no-access-log",
    ]


def service_environment() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("PYTHONUTF8", "1")
    return env


if os.name == "nt":
    import servicemanager
    import win32event
    import win32service
    import win32serviceutil

    class NerudsBridgeService(win32serviceutil.ServiceFramework):
        _svc_name_ = SERVICE_NAME
        _svc_display_name_ = SERVICE_DISPLAY_NAME
        _svc_description_ = SERVICE_DESCRIPTION

        def __init__(self, args: list[str]) -> None:
            super().__init__(args)
            self.stop_event = win32event.CreateEvent(None, 0, 0, None)
            self.process: subprocess.Popen[bytes] | None = None

        def _stop_child(self) -> None:
            process = self.process
            if process is None or process.poll() is not None:
                return
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

        def SvcStop(self) -> None:
            self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
            win32event.SetEvent(self.stop_event)
            self._stop_child()

        def SvcDoRun(self) -> None:
            servicemanager.LogInfoMsg(f"{SERVICE_NAME}: starting")
            try:
                self.process = subprocess.Popen(
                    uvicorn_command(),
                    cwd=BRIDGE_DIR,
                    env=service_environment(),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                )
                while True:
                    wait_result = win32event.WaitForSingleObject(self.stop_event, 1000)
                    if wait_result == win32event.WAIT_OBJECT_0:
                        break
                    exit_code = self.process.poll()
                    if exit_code is not None:
                        raise RuntimeError(
                            f"uvicorn exited unexpectedly with code {exit_code}"
                        )
            except Exception as exc:
                servicemanager.LogErrorMsg(f"{SERVICE_NAME}: {exc.__class__.__name__}")
                raise
            finally:
                self._stop_child()
                servicemanager.LogInfoMsg(f"{SERVICE_NAME}: stopped")


def main() -> None:
    if os.name != "nt":
        raise SystemExit("NERUDS Windows Service can only be managed on Windows.")

    import win32serviceutil

    win32serviceutil.HandleCommandLine(NerudsBridgeService)


if __name__ == "__main__":
    main()
