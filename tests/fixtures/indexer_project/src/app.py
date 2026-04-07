"""Sample Python application for indexer integration tests."""

from models import User


def create_user(name, email):
    """Create and validate a new user."""
    user = User(name, email)
    if user.validate():
        return user
    return None


def get_user_display(user):
    """Format user for display."""
    return f"{user.name} <{user.email}>"
