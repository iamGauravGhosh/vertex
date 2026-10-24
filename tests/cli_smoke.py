"""CI executable checks. Usage: python3 tests/cli_smoke.py zig-out/bin/vertex"""

import os
from pathlib import Path
import subprocess
import sys
import unittest


EXECUTABLE = Path(sys.argv.pop(1)).resolve()
SOURCE_ROOT = Path(__file__).resolve().parent.parent


def invoke(*args, data=b""):
    return subprocess.run(
        [str(EXECUTABLE), *args],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )


class CliSmoke(unittest.TestCase):
    def test_default_help_and_invalid_arguments(self):
        for args in [("--help",), ("-h",), ("parse", "--help")]:
            result = invoke(*args)
            self.assertEqual(result.returncode, 0)
            self.assertIn(b"Usage: vertex", result.stdout)
            self.assertEqual(result.stderr, b"")
        for args in [("unknown",), ("parse", "extra"), ("--",)]:
            result = invoke(*args)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"invalid arguments", result.stderr)

    def test_window_launch_reports_a_missing_display_without_reading_stdin(self):
        environment = os.environ.copy()
        environment.pop("WAYLAND_SOCKET", None)
        environment["WAYLAND_DISPLAY"] = "/vertex/no-such-wayland-display"
        result = subprocess.run(
            [str(EXECUTABLE)], input=b"", capture_output=True,
            env=environment, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertTrue(
            b"Wayland" in result.stderr or b"GuiDisabled" in result.stderr,
            result.stderr,
        )

    def test_piped_colors_unicode_and_controls(self):
        result = invoke("parse", data="\x1b[31mAé\x1b[0m\n".encode())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(
            result.stdout,
            b'CSI prefix="" params=[31] intermediates="" final="m"\n'
            b'PRINT U+0041 "A"\n'
            b'PRINT U+00E9 "\\xC3\\xA9"\n'
            b'CSI prefix="" params=[0] intermediates="" final="m"\n'
            b'EXECUTE 0x0A\n',
        )

    def test_strings_and_input_larger_than_the_read_buffer(self):
        data = (
            b"x" * 4095
            + "🙂".encode()
            + b"\x1b]8;;https://example.com/a;b\x1b\\"
            + b"\x1bP$qA\x1b\\"
            + b"\xf0\x9f"
        )
        result = invoke("parse", data=data)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout.count(b'PRINT U+0078 "x"\n'), 4095)
        self.assertEqual(result.stdout.count(b"PRINT U+1F642"), 1)
        self.assertIn(b'OSC terminator=st data="8;;https://example.com/a;b"', result.stdout)
        self.assertIn(b"DCS_DATA 0x41\nDCS_END st\n", result.stdout)
        self.assertTrue(result.stdout.endswith(b'PRINT U+FFFD "\\xEF\\xBF\\xBD"\n'))
        self.assertTrue(all(c == 10 or 32 <= c <= 126 for c in result.stdout))

    def test_oversized_osc_is_discarded_and_recovers(self):
        result = invoke("parse", data=b"\x1b]2;" + b"a" * 4096 + b"\x07Z")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'PRINT U+005A "Z"\n')

    def test_large_image_transport_streams_and_finalizes(self):
        data = (
            b"\x1b]1337;File=inline=1:" + b"A" * 12000 + b"\x07"
            + b"\x1b_Ga=T;" + b"B" * 9000 + b"\x1b\\"
            + b"\x1bPq@\x1b\\\x1b_"
        )
        result = invoke("parse", "--stream-strings", data=data)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout.count(b"OSC_DATA 0x41\n"), 12000)
        self.assertEqual(result.stdout.count(b"APC_DATA 0x42\n"), 9000)
        self.assertIn(b"OSC_END bel\nAPC_BEGIN\n", result.stdout)
        self.assertIn(b"APC_END st\nDCS_BEGIN", result.stdout)
        self.assertIn(b"DCS_DATA 0x40\nDCS_END st\n", result.stdout)
        self.assertTrue(result.stdout.endswith(b"APC_BEGIN\nAPC_END end_of_input\n"))
        self.assertTrue(all(c == 10 or 32 <= c <= 126 for c in result.stdout))

    @unittest.skipUnless(Path("/dev/full").exists(), "requires /dev/full")
    def test_output_failure_has_a_failing_status_and_diagnostic(self):
        with open("/dev/full", "wb") as output:
            result = subprocess.run(
                [str(EXECUTABLE), "parse"],
                input=b"A",
                stdout=output,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"WriteFailed", result.stderr)

    @unittest.skipUnless(os.name == "posix", "requires a directory file descriptor")
    def test_input_failure_has_a_failing_status_and_diagnostic(self):
        directory = os.open(SOURCE_ROOT, os.O_RDONLY)
        try:
            result = subprocess.run(
                [str(EXECUTABLE), "parse"],
                stdin=directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
        finally:
            os.close(directory)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ReadFailed", result.stderr)

    def test_installed_distribution_retains_vertex_license(self):
        installed = EXECUTABLE.parent.parent / "share" / "licenses" / "vertex"
        self.assertEqual(
            (installed / "LICENSE").read_bytes(), (SOURCE_ROOT / "LICENSE").read_bytes()
        )
        self.assertEqual({p.name for p in installed.iterdir()}, {"LICENSE"})


if __name__ == "__main__":
    unittest.main()
