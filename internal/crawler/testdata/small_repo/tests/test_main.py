from src.lib import greet


def test_greet():
    assert greet("there") == "Hello, there!"
