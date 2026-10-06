import os

import windows_service


def test_windows_service_binds_only_to_loopback():
    command = windows_service.uvicorn_command("python.exe")
    assert command[:4] == ["python.exe", "-m", "uvicorn", "main:app"]
    assert "--host" in command
    assert command[command.index("--host") + 1] == "127.0.0.1"
    assert "0.0.0.0" not in command
    assert "--port" in command
    assert command[command.index("--port") + 1] == "8787"
    assert "--no-access-log" in command


def test_windows_service_name_is_stable():
    assert windows_service.SERVICE_NAME == "NERUDS-Control-Bridge"
    assert os.path.basename(str(windows_service.BRIDGE_DIR)) == "bridge"
