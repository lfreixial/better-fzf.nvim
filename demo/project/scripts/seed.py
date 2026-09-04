"""Seed the demo database with greetings."""

GREETINGS = ["hello", "hey", "hi", "howdy"]


def make_handler(name: str) -> str:
    # TODO: handle empty names
    return f"{GREETINGS[0]}, {name}"


if __name__ == "__main__":
    for who in ("world", "demo"):
        print(make_handler(who))
