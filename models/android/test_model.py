import unittest
import torch

try:
    import model
except ModuleNotFoundError:
    model = None


class AndroidModelTests(unittest.TestCase):
    def test_recovered_checkpoint_matches_packaged_onnx(self):
        self.assertIsNotNone(model, "Android model source has not been packaged")
        import numpy as np
        import onnxruntime as ort
        torch.set_num_threads(2)
        graph = model.load_graph()
        self.assertEqual(sum(p.numel() for p in graph.model.parameters()), 5034030)
        image = np.full((1, 3, 480, 480), 128 / 255, dtype=np.float32)
        with torch.inference_mode():
            actual = [value.numpy() for value in graph(torch.from_numpy(image))]
        session = ort.InferenceSession(str(model.PACKAGED_ONNX), providers=["CPUExecutionProvider"])
        expected = session.run(None, {"image": image})
        self.assertEqual([value.shape for value in actual], [(1, 4725, 4), (1, 4725), (1, 4725), (1, 4725), (1, 4725, 2)])
        for index, (left, right) in enumerate(zip(actual, expected)):
            if index in (2, 3):
                np.testing.assert_array_equal(left, right)
            else:
                np.testing.assert_allclose(left, right, rtol=1e-4, atol=.002 if index == 0 else 1e-4)


if __name__ == "__main__":
    unittest.main()
