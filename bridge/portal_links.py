"""Portal URL helpers shared by the API layer and the mission store.

All validation goes through the configured portal origin + base path so
foreign or off-prefix URLs can never masquerade as local node links.
Callers pass their own ``PORTAL_URL`` (or omit it for the env default)
so tests can monkeypatch per-module constants.
"""

from __future__ import annotations

import os
import re
from urllib.parse import urlparse

PORTAL_URL = os.getenv("NERUDS_PORTAL_URL", "https://neruds.org").rstrip("/")

NODE_PATH_RE = re.compile(r"^/node/(\d+)(/edit)?/?$")


def portal_url_path(url: str, portal_url: str | None = None) -> str | None:
    """Portal-relative path when *url* shares the configured portal's
    scheme, origin and base path; None otherwise."""
    portal = urlparse((portal_url or PORTAL_URL).rstrip("/"))
    try:
        parsed = urlparse(str(url))
        default_port = {"https": 443, "http": 80}
        if (
            parsed.scheme not in ("http", "https")
            or parsed.username
            or parsed.password
            or (
                parsed.scheme,
                parsed.hostname,
                parsed.port or default_port.get(parsed.scheme),
            )
            != (
                portal.scheme,
                portal.hostname,
                portal.port or default_port.get(portal.scheme),
            )
        ):
            return None
    except ValueError:
        return None
    base_path = portal.path.rstrip("/")
    path = parsed.path
    if base_path:
        if not path.startswith(base_path + "/"):
            return None
        path = path[len(base_path):]
    return path


def portal_node_parts(
    url: str, portal_url: str | None = None
) -> tuple[str, bool] | None:
    """Return (nid, is_edit) when *url* is a /node/{nid}[/edit] portal page."""
    path = portal_url_path(url, portal_url)
    if path is None:
        return None
    match = NODE_PATH_RE.match(path)
    if not match:
        return None
    return match.group(1), match.group(2) == "/edit"


def portal_node_nid(url: str, portal_url: str | None = None) -> str | None:
    parts = portal_node_parts(url, portal_url)
    return parts[0] if parts else None


def portal_node_link(
    url: str, *, require_edit: bool, portal_url: str | None = None
) -> bool:
    """True when *url* is a portal /node link of exactly the expected kind —
    the /edit suffix must be present for edit_url and absent for public_url."""
    parts = portal_node_parts(url, portal_url)
    return parts is not None and parts[1] == require_edit
