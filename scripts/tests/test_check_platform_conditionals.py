"""Tests for scripts/check-platform-conditionals.py.

The ratchet that keeps platform `#if`s out of the Apple app layer's shared
code (docs/apple.md, "Platform conditionals"). Pinned here: what counts as a
platform conditional, which files are exempt, that a planted file and a raised
count both fail, that a row left above its count is reported without failing,
and that the repository's own tree passes against its own allowlist.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-platform-conditionals.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_platform_conditionals", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CountingTests(unittest.TestCase):
    """Which lines are platform conditionals."""

    def setUp(self):
        self.c = load_checker()

    def count(self, source):
        return self.c.counted_lines(textwrap.dedent(source))

    def test_os_conditions_count_with_or_without_negation(self):
        source = """\
        #if os(macOS)
        #endif
            #if !os(iOS)
            #endif
        #if os(iOS) || os(visionOS)
        #endif
        """
        self.assertEqual(self.count(source), [1, 3, 5])

    def test_the_space_after_the_directive_is_not_required(self):
        # Swift reads `#if` as its own token, so a parenthesis or a tab ends it.
        self.assertEqual(self.count("#if(os(macOS))\n#endif\n#if\tos(iOS)\n#endif\n#ifdef os(iOS)\n"), [1, 3])

    def test_ui_framework_imports_count_and_others_do_not(self):
        source = """\
        #if canImport(UIKit)
        #endif
        #if canImport(AppKit)
        #endif
        #if canImport(EventKitUI)
        #endif
        #if canImport(WebKit)
        #endif
        #if canImport(Network)
        #endif
        #if DEBUG
        #endif
        #if compiler(>=6.2)
        #endif
        """
        self.assertEqual(self.count(source), [1, 3, 5])

    def test_else_arms_never_count_and_a_nested_if_counts_on_its_own_line(self):
        source = """\
        #if os(macOS)
        #elseif os(iOS)
            #if os(iOS)
            #endif
        #else
        #endif
        """
        self.assertEqual(self.count(source), [1, 3])

    def test_the_directive_must_lead_its_line(self):
        self.assertEqual(self.count("// #if os(iOS)\nlet x = 1 // #if os(iOS)\n"), [])


class ExemptionTests(unittest.TestCase):
    """A UIKit or AppKit wrapper file is the OS adapter itself."""

    def setUp(self):
        self.c = load_checker()

    def test_each_representable_protocol_exempts_its_file(self):
        for protocol in (
            "UIViewRepresentable", "NSViewRepresentable",
            "UIViewControllerRepresentable", "NSViewControllerRepresentable",
        ):
            with self.subTest(protocol=protocol):
                self.assertTrue(self.c.is_wrapper(f"struct Wrapper: {protocol} {{\n}}\n"))

    def test_a_class_or_extension_with_more_conformances_exempts_too(self):
        self.assertTrue(self.c.is_wrapper("final class Host: NSObject, UIViewControllerRepresentable {}"))
        self.assertTrue(self.c.is_wrapper("extension Field: NSViewRepresentable {\n}"))
        self.assertTrue(self.c.is_wrapper("struct Box<Content: View>: UIViewRepresentable {}"))

    def test_a_gesture_recognizer_wrapper_is_not_exempt(self):
        self.assertFalse(self.c.is_wrapper("struct Click: UIGestureRecognizerRepresentable {}"))

    def test_the_protocol_is_matched_as_a_whole_word(self):
        self.assertFalse(self.c.is_wrapper("struct Box: MyUIViewRepresentableBox {}"))

    def test_a_where_clause_is_not_the_inheritance_clause(self):
        self.assertFalse(self.c.is_wrapper("struct Host<W>: View where W: UIViewRepresentable {}"))
        self.assertFalse(self.c.is_wrapper("extension Array: Sequence where Element: NSViewRepresentable {}"))
        self.assertTrue(self.c.is_wrapper("struct Host<W>: UIViewRepresentable where W: View {}"))

    def test_a_name_in_a_comment_or_a_string_does_not_exempt(self):
        self.assertFalse(self.c.is_wrapper("/// struct Old: UIViewRepresentable {}\nstruct New: View {}"))
        self.assertFalse(self.c.is_wrapper("/* struct Old: NSViewRepresentable {} */\nstruct New: View {}"))
        self.assertFalse(self.c.is_wrapper('let note = "struct Old: UIViewRepresentable {"\n'))

    def test_using_a_wrapper_is_not_being_one(self):
        self.assertFalse(self.c.is_wrapper("struct Screen: View {\n    var body: some View { Wrapper() }\n}"))


class RatchetTests(unittest.TestCase):
    """A new file and a raised count fail; a row left high is reported."""

    def setUp(self):
        self.c = load_checker()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.ui = self.root / "apple" / "CabalmailUI"
        self.write("Mail/Listed.swift", "#if os(macOS)\n#endif\n#if os(iOS)\n#endif\n")
        self.write("Shell/Layout.swift", "#if os(iOS)\n#endif\n")
        self.write("Platform/Adapter.swift", "#if os(macOS)\n#endif\n")
        self.write("Shared/Wrapper.swift", "#if os(iOS)\nstruct W: UIViewRepresentable {}\n#endif\n")
        self.allow("Mail/Listed.swift 2\n")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, source):
        path = self.ui / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def allow(self, rows):
        (self.root / "apple" / "platform-conditionals-allowlist.txt").write_text(
            "# path under apple/CabalmailUI/, then its count\n" + rows, encoding="utf-8"
        )

    def run_check(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = self.c.main(["--root", str(self.root)])
        return status, out.getvalue()

    def test_the_seeded_tree_passes(self):
        status, out = self.run_check()
        self.assertEqual(status, 0, out)
        self.assertIn("1 files, 2 blocks", out)

    def test_shell_platform_and_wrappers_are_out_of_scope(self):
        self.assertEqual(list(self.c.census(self.root)), ["Mail/Listed.swift"])

    def test_only_the_top_level_shell_and_platform_folders_are_out_of_scope(self):
        self.write("Mail/Shell/Nested.swift", "#if os(iOS)\n#endif\n")
        status, out = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("apple/CabalmailUI/Mail/Shell/Nested.swift:1:", out)

    def test_a_planted_file_fails_at_its_first_conditional(self):
        self.write("Feeds/Planted.swift", "import SwiftUI\n\n#if os(visionOS)\n#endif\n")
        status, out = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("apple/CabalmailUI/Feeds/Planted.swift:3:", out)

    def test_a_raised_count_fails_at_the_first_one_over(self):
        self.write("Mail/Listed.swift", "#if os(macOS)\n#endif\n#if os(iOS)\n#endif\n#if canImport(UIKit)\n#endif\n")
        status, out = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("apple/CabalmailUI/Mail/Listed.swift:5: 3 platform #ifs", out)

    def test_a_lowered_count_is_reported_and_does_not_fail(self):
        self.write("Mail/Listed.swift", "#if os(macOS)\n#endif\n")
        status, out = self.run_check()
        self.assertEqual(status, 0, out)
        self.assertIn("Mail/Listed.swift has 1 platform #ifs now; lower its row from 2 to 1", out)

    def test_a_cleared_file_is_reported_and_does_not_fail(self):
        self.write("Mail/Listed.swift", "import SwiftUI\n")
        status, out = self.run_check()
        self.assertEqual(status, 0, out)
        self.assertIn("Mail/Listed.swift has no counted platform #ifs now; remove its row", out)

    def test_a_stale_row_is_a_warning_annotation_in_ci(self):
        self.write("Mail/Listed.swift", "#if os(macOS)\n#endif\n")
        before = os.environ.get("GITHUB_ACTIONS")
        os.environ["GITHUB_ACTIONS"] = "true"
        try:
            status, out = self.run_check()
        finally:
            if before is None:
                del os.environ["GITHUB_ACTIONS"]
            else:
                os.environ["GITHUB_ACTIONS"] = before
        self.assertEqual(status, 0, out)
        self.assertIn("::warning file=apple/platform-conditionals-allowlist.txt::Mail/Listed.swift has 1", out)

    def test_a_stale_row_does_not_hide_a_planted_file(self):
        self.write("Mail/Listed.swift", "#if os(macOS)\n#endif\n")
        self.write("Feeds/Planted.swift", "#if os(iOS)\n#endif\n")
        status, out = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("apple/CabalmailUI/Feeds/Planted.swift:1:", out)

    def test_seed_prints_the_rows_the_tree_needs(self):
        self.write("Feeds/Planted.swift", "#if os(visionOS)\n#endif\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.c.main(["--root", str(self.root), "--seed"])
        self.assertEqual(out.getvalue(), "Feeds/Planted.swift 1\nMail/Listed.swift 2\n")

    def test_the_seed_is_an_allowlist_the_tree_passes(self):
        self.write("Feeds/Planted.swift", "#if os(visionOS)\n#endif\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.c.main(["--root", str(self.root), "--seed"])
        self.allow(out.getvalue())
        status, checked = self.run_check()
        self.assertEqual(status, 0, checked)
        self.assertNotIn("its row", checked)

    def test_a_row_without_a_count_names_its_line(self):
        self.allow("Mail/Listed.swift\n")
        with self.assertRaises(SystemExit) as raised:
            self.run_check()
        self.assertIn("platform-conditionals-allowlist.txt:2:", str(raised.exception))


class RepositoryTests(unittest.TestCase):
    """The repository's tree is within its own allowlist."""

    def test_the_repository_passes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = load_checker().main([])
        self.assertEqual(status, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
