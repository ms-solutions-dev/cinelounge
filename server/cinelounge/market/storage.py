"""What the marketplace needs from a store — and nothing more.

**The layer contract forced this, and it was right.** The first attempt
imported `household.store` directly; `lint-imports` refused, because `market`
and `household` are siblings and neither is meant to know the other.

The temptation would have been to loosen the contract. What comes out of that
is a dependency nobody can see any more: the marketplace would hang off the
household although it needs one table, and at the next rebuild one would drag
the other along.

Instead, what stands here is **what is needed**: a thing with `connect()` that
yields a context around a database connection. Whoever builds the marketplace
hands it one — today that is `household.store.Store`, tomorrow it may be
something else, and this module will not notice.
"""

from __future__ import annotations

from contextlib import AbstractContextManager
from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Storage(Protocol):
    """A store as `sources` and `trust` use it."""

    def connect(self) -> AbstractContextManager[Any]:
        """A connection that commits or rolls back at the end of the block."""
        ...

    def read(self, key: str, fallback: str = "") -> str:
        """Read one household value — for the marketplace's own settings."""
        ...
