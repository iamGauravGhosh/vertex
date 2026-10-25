"""Real Textual key, resize, rich text and synchronized-output fixture."""
from textual.app import App, ComposeResult
from textual.widgets import Static


class Fixture(App):
    BINDINGS = [("q", "quit", "Quit")]

    def compose(self) -> ComposeResult:
        yield Static("[cyan underline]VERTEX_FRAMEWORK_READY[/]\n界 é 👩‍💻", id="body")

    def on_key(self, event):
        if event.key != "q":
            self.query_one("#body", Static).update("VERTEX_FRAMEWORK_INPUT " + (event.character or event.key))


Fixture().run()
