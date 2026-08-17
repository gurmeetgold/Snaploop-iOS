#!/usr/bin/env python3
"""
Convert an open face-recognition model to the Core ML package SnapLoop expects.

WHY THIS IS A SCRIPT AND NOT A CHECKED-IN MODEL
-----------------------------------------------
The SnapLoop repo does NOT ship a face-embedding model. Producing one requires
downloading pretrained weights and running coremltools, neither of which can
happen inside the sandbox where this repo is authored (no network, no
coremltools). Run this on a Mac/Linux box with internet to produce
`SnapLoopFaceEmbedding.mlpackage`, then add it to the SnapLoop target.

LICENSING — READ BEFORE YOU SHIP
--------------------------------
Most high-accuracy open face models (ArcFace / InsightFace, FaceNet, many
MobileFaceNet checkpoints) are released for NON-COMMERCIAL / research use only,
or under licenses whose commercial terms you must verify per checkpoint. That
is FINE for internal development and benchmarking, and NOT cleared for a
shipping product. Treat any model produced by this script as DEV-ONLY until a
commercially-licensed (or self-trained) checkpoint is substituted. This mirrors
the repo's DevStubs / FaceModelPolicy.usesDevelopmentDescriptor convention:
dev-grade until explicitly cleared. Do not ship research weights to the App
Store as if they were production-cleared.

INPUT CONTRACT SnapLoop EXPECTS
-------------------------------
- Image input, 112x112 RGB (FaceAligner already produces an aligned square crop;
  Vision scales to the model's input size).
- A single MultiArray output = the face embedding (e.g. 512-d for ArcFace).
  Feature names don't matter: CoreMLFaceEmbeddingEngine discovers the image
  input and the MultiArray output from the model description.
- SnapLoop L2-normalizes the embedding itself (FaceEmbedding.init), so the model
  need not normalize, though it's fine if it does.

USAGE
-----
  pip install coremltools onnx  # (+ torch, if converting from a .pt)
  python3 convert_face_model.py --onnx arcface_r100.onnx --out SnapLoopFaceEmbedding.mlpackage

This is a TEMPLATE. ArcFace-family models expect BGR input normalized as
(x - 127.5) / 128.0. Adjust bias/scale/channel order to match YOUR checkpoint's
training preprocessing — a normalization mismatch silently destroys accuracy.
"""

import argparse
import sys


def convert(onnx_path: str, out_path: str, input_size: int) -> None:
    try:
        import coremltools as ct
    except ImportError:
        sys.exit("coremltools is required: pip install coremltools")

    # ArcFace-style preprocessing: (pixel - 127.5) / 128.0 == pixel/128 - 0.99609
    # coremltools ImageType applies: output = pixel * scale + bias (per channel).
    scale = 1.0 / 128.0
    bias = [-127.5 / 128.0] * 3

    image_input = ct.ImageType(
        name="input_image",
        shape=(1, 3, input_size, input_size),
        scale=scale,
        bias=bias,
        color_layout=ct.colorlayout.BGR,  # ArcFace/InsightFace convention; RGB for FaceNet
    )

    model = ct.convert(
        onnx_path,
        inputs=[image_input],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.ALL,
    )
    model.short_description = (
        "SnapLoop face-embedding model. DEV-ONLY unless the source checkpoint's "
        "commercial license has been verified. See tools/FACE_MODEL.md."
    )
    model.save(out_path)
    print(f"Wrote {out_path}. Verify normalization matches your checkpoint's training.")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--onnx", required=True, help="Path to the source ONNX model")
    p.add_argument("--out", default="SnapLoopFaceEmbedding.mlpackage")
    p.add_argument("--input-size", type=int, default=112)
    args = p.parse_args()
    convert(args.onnx, args.out, args.input_size)
