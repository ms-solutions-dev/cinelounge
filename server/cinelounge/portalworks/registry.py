"""The register — manifests from the folder, code only later.

Startup only reads. A portal whose code crashes therefore cannot take the
container down with it: it shows up as "broken" in the list, with the reason
beside it, and the others carry on.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

from cinelounge.portalworks import routes
from cinelounge.portalworks.manifest import Manifest, overlay, read


class Registry:
    """The register.

    `overrides` is a **callback, not a dependency**, and that is deliberate:
    the values an operator stores live in the household — but `portalworks`
    must not import `household`, the layer contract in `setup.cfg` insists on
    it. Who fetches the values is the caller's business; the register only
    knows that there may be some.
    """

    def __init__(
        self,
        root: Path,
        overrides: Callable[[str], dict[str, str]] | None = None,
    ) -> None:
        self.root = root
        self.overrides = overrides
        self.manifests: dict[str, Manifest] = {}
        self.reload()

    def reload(self) -> None:
        found: list[Manifest] = []
        if self.root.is_dir():
            for item in sorted(self.root.iterdir()):
                if not item.is_dir() or item.name.startswith((".", "_")):
                    continue
                file = item / "portal.yml"
                if file.exists():
                    m = read(file)
                    if self.overrides is not None:
                        overlay(m, self.overrides(m.id))
                    found.append(m)

        # Duplicate ids would otherwise only surface when an address hits the
        # wrong portal.
        watched: set[str] = set()
        for m in found:
            if m.is_ready and m.id in watched:
                m.broken_reason = "duplicate id: " + m.id
            elif m.is_ready:
                watched.add(m.id)
            # **A portal whose route is gone is broken, not direct.** Sending
            # it out directly would look like a portal behaving oddly, and the
            # operator would go looking in the wrong place. The reason names
            # the route, and the network page shows the portal under
            # "without_exit". Set the route up again, and the next reload says
            # `ready` without anybody touching the portal.
            if m.is_ready and routes.missing(m):
                m.broken_reason = "no exit for net: " + m.exit_net
        self.manifests = {m.id: m for m in found}

    def ready(self) -> list[Manifest]:
        """Everything that could be read. Who is allowed to see it is decided
        by `household.visibility.Visibility` — the layer contract insists on
        that, and rightly so: a manifest does not know who lives in the
        house."""
        return [m for m in self.manifests.values() if m.is_ready]

    def status(self) -> dict[str, Any]:
        """Counts for `/health` and the workshop's reload.

        **A portal waiting for a setting is not `broken`.** It stands under
        `needs_setting` with the empty keys instead: a monitor that alarms on
        a non-empty `broken` must not ring because the operator has not typed
        an API key yet. `ready` stays the count of ready portals, so
        `ready + len(broken) + len(needs_setting) == portals`.
        """
        broken_reason = [
            {"id": m.id, "reason": m.broken_reason}
            for m in self.manifests.values()
            if not m.is_ready and not m.needs_setting
        ]
        needs_setting = [
            {"id": m.id, "reason": m.broken_reason, "settings": list(m.missing_settings)}
            for m in self.manifests.values()
            if m.needs_setting
        ]
        return {
            "portals": len(self.manifests),
            "ready": len(self.manifests) - len(broken_reason) - len(needs_setting),
            "broken": broken_reason,
            "needs_setting": needs_setting,
        }
