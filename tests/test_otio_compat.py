#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager
from pathlib import Path


class FakeFastMCP:
    def __init__(self, name, instructions=""):
        self.name = name
        self.instructions = instructions
        self.tools = []
        self.resources = []
        self.prompts = []

    def tool(self, annotations=None):
        def decorator(func):
            self.tools.append({"name": func.__name__, "annotations": dict(annotations or {}), "func": func})
            return func

        return decorator

    def resource(self, uri, **kwargs):
        def decorator(func):
            self.resources.append({"uri": uri, "func": func, **kwargs})
            return func

        return decorator

    def prompt(self, **kwargs):
        def decorator(func):
            self.prompts.append({"func": func, **kwargs})
            return func

        return decorator


def load_server_module():
    repo_root = Path(__file__).resolve().parents[1]
    module_path = repo_root / "mcp" / "server.py"

    fake_mcp = types.ModuleType("mcp")
    fake_mcp_server = types.ModuleType("mcp.server")
    fake_fastmcp = types.ModuleType("mcp.server.fastmcp")
    fake_fastmcp.FastMCP = FakeFastMCP

    injected_modules = {
        "mcp": fake_mcp,
        "mcp.server": fake_mcp_server,
        "mcp.server.fastmcp": fake_fastmcp,
    }
    previous_modules = {name: sys.modules.get(name) for name in injected_modules}

    try:
        sys.modules.update(injected_modules)
        spec = importlib.util.spec_from_file_location("splicekit_mcp_server_under_test", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module
    finally:
        for name, previous in previous_modules.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


class FakeTrack(list):
    pass


class FakeTimeline:
    def __init__(self, tracks=None):
        self.tracks = tracks or []


class FakeGap:
    def __init__(self, source_range=None):
        self.source_range = source_range


class FakeGeneratorReference:
    def __init__(self, generator_kind="", parameters=None):
        self.generator_kind = generator_kind
        self.parameters = parameters or {}


class FakeClip:
    def __init__(self, media_reference=None, source_range=None):
        self.media_reference = media_reference
        self.source_range = source_range


class OTIOCompatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()

    @contextmanager
    def fake_otio(self, *, available_adapters=None):
        available_adapters = list(available_adapters or [])

        class FakeAdapters:
            def available_adapter_names(self_inner):
                return list(available_adapters)

        fake_otio = types.SimpleNamespace(
            adapters=FakeAdapters(),
            schema=types.SimpleNamespace(
                Timeline=FakeTimeline,
                Track=FakeTrack,
                Gap=FakeGap,
                Clip=FakeClip,
                GeneratorReference=FakeGeneratorReference,
            ),
        )

        previous = sys.modules.get("opentimelineio")
        sys.modules["opentimelineio"] = fake_otio
        try:
            yield fake_otio
        finally:
            if previous is None:
                sys.modules.pop("opentimelineio", None)
            else:
                sys.modules["opentimelineio"] = previous

    def test_adapter_candidates_prefer_modern_fcpxml_name(self):
        with self.fake_otio(available_adapters=["fcpx_xml", "fcpxml"]):
            self.assertEqual(
                self.module._otio_fcpx_adapter_candidates(),
                ["fcpxml", "fcpx_xml"],
            )

    def test_adapter_operation_falls_back_to_legacy_name(self):
        with self.fake_otio(available_adapters=["fcpxml", "fcpx_xml"]):
            calls = []

            def operation(name):
                calls.append(name)
                if name == "fcpxml":
                    raise RuntimeError("missing plugin")
                return "ok"

            self.assertEqual(self.module._otio_with_fcpx_adapter(operation), "ok")
            self.assertEqual(calls, ["fcpxml", "fcpx_xml"])

    def test_prepare_for_fcp_preserves_title_generators_across_metadata_variants(self):
        with self.fake_otio():
            title_kind = FakeClip(
                media_reference=FakeGeneratorReference(generator_kind="fcpx.title"),
                source_range="kind-range",
            )
            title_params = FakeClip(
                media_reference=FakeGeneratorReference(parameters={"text_xml": ["<text/>"]}),
                source_range="param-range",
            )
            non_title = FakeClip(
                media_reference=FakeGeneratorReference(generator_kind="fcpx.generator"),
                source_range="gap-range",
            )
            timeline = FakeTimeline(tracks=[FakeTrack([title_kind, title_params, non_title])])

            prepared = self.module._otio_prepare_for_fcp(timeline)

            self.assertIs(prepared.tracks[0][0], title_kind)
            self.assertIs(prepared.tracks[0][1], title_params)
            self.assertIsInstance(prepared.tracks[0][2], FakeGap)
            self.assertEqual(prepared.tracks[0][2].source_range, "gap-range")

    def test_read_fcpx_document_reads_package_entrypoint(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            package_path = Path(tmpdir) / "Example.fcpxmld"
            package_path.mkdir()
            info_path = package_path / "Info.fcpxml"
            info_path.write_text("<fcpxml version='1.14'/>", encoding="utf-8")

            self.assertEqual(
                self.module._otio_read_fcpx_document(str(package_path)),
                "<fcpxml version='1.14'/>",
            )


if __name__ == "__main__":
    unittest.main()
