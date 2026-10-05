"""Startup problems worth showing an admin (see the admin panel)."""

# Set when database/postgres/schema.sql could not be applied at startup —
# new features that need new tables/columns would be broken until fixed.
schema_error: str | None = None
