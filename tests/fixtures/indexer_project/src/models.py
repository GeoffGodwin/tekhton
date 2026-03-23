"""Data models for the sample project."""


class User:
    """Represents a user in the system."""

    def __init__(self, name, email):
        self.name = name
        self.email = email

    def validate(self):
        """Check if user data is valid."""
        return bool(self.name) and "@" in self.email

    def to_dict(self):
        """Convert user to dictionary."""
        return {"name": self.name, "email": self.email}
