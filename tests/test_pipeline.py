"""End-to-end test of node build + generate using a fake ``nuke`` module and the
offline mock backend. Verifies the Python plumbing, not Nuke's rendering."""
import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import fake_nuke  # noqa: E402

nuke = fake_nuke.install()

from genfill import engine, node as gfnode, pngio, state  # noqa: E402


def _join_workers():
    for t in threading.enumerate():
        if t.name.startswith("GenFill-"):
            t.join(30)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        fake_nuke._root.script_path = os.path.join(self.tmp, "shot.nk")
        fake_nuke.EXECUTED[:] = []
        self.plate = nuke.nodes.Read(name="Plate")
        self.g = gfnode.create()
        self.g.setInput(0, self.plate)
        mock_label = [l for l in gfnode.backend_labels() if "Offline" in l][0]
        self.g["gf_backend"].setValue(mock_label)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_build(self):
        g = self.g
        for name in (gfnode.READ_RESULT, gfnode.COMP, gfnode.OUT_SWITCH, gfnode.PROBE_WRITE,
                     gfnode.WRITE_SRC, gfnode.WRITE_MASK, gfnode.WRITE_MASK_A):
            self.assertIsNotNone(g.node(name), name)
        for name in gfnode.WRITE_NODES:
            self.assertTrue(g.node(name)["disable"].value(), "%s must start disabled" % name)
        self.assertEqual(g.node(gfnode.OUT_SWITCH)["which"].expression,
                         "parent.gf_has_result ? parent.gf_output : 2")
        self.assertEqual(g.node(gfnode.COMP).input(2), g.node(gfnode.FEATHER))
        self.assertEqual(g.input(1).Class(), "Roto")
        self.assertTrue(g.input(1)["replace"].value())
        self.assertEqual(g["gf_variations"].value(), 3)

    def test_generate_and_select(self):
        g = self.g
        self.assertTrue(engine.generate(g, "a red vintage car"))
        _join_workers()
        st = state.loads(g["gf_state"].value())
        self.assertEqual(len(st["generations"]), 1, engine.status(g))
        gen = st["generations"][0]
        self.assertEqual(len(gen["files"]), 3)
        self.assertEqual(gen["frame"], 1001)
        self.assertEqual(gen["prompt"], "a red vintage car")

        # Selection box in the fake probe: x 40-60%, y 30-60% from top of 1920x1080.
        x, y, w, h = gen["region"]
        self.assertLessEqual(x, 0.4 * 1920)
        self.assertGreaterEqual(x + w, 0.6 * 1920)
        self.assertLessEqual(y, (1 - 0.6) * 1080)
        self.assertGreaterEqual(y + h, (1 - 0.3) * 1080)
        mw, mh = gen["model_size"]
        self.assertAlmostEqual(float(w) / h, float(mw) / mh, delta=0.03)

        # Crops were rendered at model size and in order; writes re-disabled.
        names = [e[0] for e in fake_nuke.EXECUTED]
        self.assertEqual(names, [gfnode.PROBE_WRITE, gfnode.WRITE_SRC, gfnode.WRITE_MASK,
                                 gfnode.WRITE_MASK_A])
        src = pngio.read(fake_nuke.EXECUTED[1][1])
        self.assertEqual((src.width, src.height), (mw, mh))
        for name in gfnode.WRITE_NODES:
            self.assertTrue(g.node(name)["disable"].value())

        # Result wiring.
        read = g.node(gfnode.READ_RESULT)
        self.assertTrue(read["file"].value().endswith(gen["files"][0]))
        self.assertTrue(os.path.exists(read["file"].value()))
        self.assertEqual(g.node(gfnode.REFORMAT_RECV)["box_width"].value(), w)
        self.assertEqual(g.node(gfnode.TRANSFORM_RECV)["translate"].value(), [x, y])
        self.assertTrue(g["gf_has_result"].value())
        self.assertIn("[1/3]", g["gf_info"].value())
        self.assertTrue(read["file"].value().startswith(
            os.path.join(self.tmp, "genfill_cache").replace("\\", "/")))

        # Second generation, then navigate and delete.
        self.assertTrue(engine.generate(g, ""))
        _join_workers()
        thumbs = engine.thumbnails(g)
        self.assertEqual(len(thumbs), 6)
        self.assertEqual(thumbs[0]["prompt"], "")          # newest first, selected
        self.assertTrue(thumbs[0]["selected"])
        engine.step(g, 1)
        self.assertIn("[2/6]", g["gf_info"].value())
        engine.select(g, 0, 2)
        self.assertTrue(g.node(gfnode.READ_RESULT)["file"].value().endswith("var_03.png"))
        path = engine.thumbnails(g)[5]["path"]
        engine.delete_variation(g, 0, 2)
        self.assertFalse(os.path.exists(path))
        self.assertEqual(len(engine.thumbnails(g)), 5)

    def test_empty_selection_is_reported(self):
        fake_nuke.SELECTION_BOX[:] = [0, 0, 0, 0]
        try:
            self.assertFalse(engine.generate(self.g, "x"))
            self.assertIn("selection is empty", engine.status(self.g)["error"])
            self.assertFalse(self.g["gf_has_result"].value())
        finally:
            fake_nuke.SELECTION_BOX[:] = [0.4, 0.3, 0.6, 0.6]

    def test_missing_source(self):
        self.g.setInput(0, None)
        self.assertFalse(engine.generate(self.g, "x"))
        self.assertIn("Source", engine.status(self.g)["error"])


if __name__ == "__main__":
    unittest.main()
