#!/usr/bin/env python3
"""Converts Moondream Parakeet Ultra to the sherpa-onnx int8 layout.

Moondream ships safetensors with Hugging Face transformers key names
(ParakeetForTDT), and the sherpa-onnx exporter needs a NeMo model. This loads
NVIDIA's parakeet-tdt-0.6b-v3 in NeMo (same architecture and tokenizer),
copies the Ultra weights over it by name, and exports like sherpa-onnx's
scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py (Apache-2.0, Fangjun Kuang).
The VAD head Moondream added is dropped: sherpa-onnx cannot run it.

Run on Linux or WSL (NeMo does not install cleanly on Windows), 16 GB RAM:

  pip install "nemo_toolkit[asr]" onnx onnxruntime safetensors \
      huggingface_hub sherpa-onnx
  python tool/convert_ultra.py es.wav        # any 16 kHz mono WAV, under 20 s

Output: build/ultra/{encoder,decoder,joiner}.int8.onnx and tokens.txt.
The run ends by transcribing the WAV with v3, with Ultra in NeMo and with the
int8 ONNX in sherpa-onnx: the three texts must read alike. Garbage in the
last two means a wrong key mapping.
"""

import os
import re
import sys
from pathlib import Path

import nemo.collections.asr as nemo_asr
import onnx
import sherpa_onnx
import soundfile
import torch
from huggingface_hub import hf_hub_download
from onnxruntime.quantization import QuantType, quantize_dynamic
from safetensors.torch import load_file

OUT = Path("build/ultra")

# transformers name -> NeMo name, first match wins. Checked against the
# header of moondream/parakeet-ultra model.safetensors on 2026-11-12.
RENAMES = [
    (r"^encoder\.subsampling\.layers\.", "encoder.pre_encode.conv."),
    (r"^encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"\.conv\.norm\.", ".conv.batch_norm."),
    (r"\.self_attn\.q_proj\.", ".self_attn.linear_q."),
    (r"\.self_attn\.k_proj\.", ".self_attn.linear_k."),
    (r"\.self_attn\.v_proj\.", ".self_attn.linear_v."),
    (r"\.self_attn\.o_proj\.", ".self_attn.linear_out."),
    (r"\.self_attn\.relative_k_proj\.", ".self_attn.linear_pos."),
    (r"\.self_attn\.bias_u$", ".self_attn.pos_bias_u"),
    (r"\.self_attn\.bias_v$", ".self_attn.pos_bias_v"),
    (r"^decoder\.embedding\.", "decoder.prediction.embed."),
    (r"^decoder\.lstm\.", "decoder.prediction.dec_rnn.lstm."),
    (r"^decoder\.decoder_projector\.", "joint.pred."),
    (r"^encoder_projector\.", "joint.enc."),
]


def to_nemo(ultra: dict, base: dict) -> dict:
    """Ultra tensors under NeMo names, as float32. Exits on any mismatch."""
    # The joint output layer sits at joint.joint_net.<n>, where n depends on
    # whether the model has dropout: read it from the base model.
    (head,) = [
        k[: -len("weight")] for k in base if re.fullmatch(r"joint\.joint_net\.\d+\.weight", k)
    ]
    out, unknown = {}, []
    for name, tensor in ultra.items():
        if name.startswith("vad_head."):
            continue
        new = name.replace("joint.head.", head) if name.startswith("joint.head.") else name
        for pattern, to in RENAMES:
            new, n = re.subn(pattern, to, new)
            if n:
                break
        if new not in base or base[new].shape != tensor.shape:
            unknown.append(f"{name} -> {new} {tuple(tensor.shape)}")
            continue
        out[new] = tensor.float() if tensor.is_floating_point() else tensor
    # Every trained weight of the base model must be replaced, or the result
    # is a silent mix of v3 and Ultra.
    left = [
        k for k in base if k.split(".")[0] in ("encoder", "decoder", "joint") and k not in out
    ]
    if unknown or left:
        sys.exit(
            "Key mapping failed.\nUltra keys with no NeMo match (or another shape):\n  "
            + "\n  ".join(unknown or ["none"])
            + "\nNeMo keys Ultra did not fill:\n  "
            + "\n  ".join(left or ["none"])
        )
    return out


def add_meta_data(filename: str, meta_data: dict):
    model = onnx.load(filename)
    del model.metadata_props[:]
    for key, value in meta_data.items():
        meta = model.metadata_props.add()
        meta.key = key
        meta.value = str(value)
    onnx.save(model, filename)


@torch.no_grad()
def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    wav = str(Path(sys.argv[1]).resolve())

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    model.eval()
    v3_text = model.transcribe([wav])[0].text

    base = model.state_dict()
    ultra = load_file(hf_hub_download("moondream/parakeet-ultra", "model.safetensors"))
    # strict=False only for the keys outside encoder/decoder/joint (the
    # preprocessor buffers), which stay as in v3. to_nemo checked the rest.
    model.load_state_dict(to_nemo(ultra, base), strict=False)
    ultra_text = model.transcribe([wav])[0].text

    OUT.mkdir(parents=True, exist_ok=True)
    os.chdir(OUT)  # the fp32 encoder export leaves its weight files here

    with open("tokens.txt", "w", encoding="utf-8") as f:
        for i, s in enumerate(model.joint.vocabulary):
            f.write(f"{s} {i}\n")
        f.write(f"<blk> {i + 1}\n")

    model.encoder.export("encoder.onnx")
    model.decoder.export("decoder.onnx")
    model.joint.export("joiner.onnx")
    for m in ["encoder", "decoder", "joiner"]:
        quantize_dynamic(
            model_input=f"{m}.onnx",
            model_output=f"{m}.int8.onnx",
            weight_type=QuantType.QUInt8 if m == "encoder" else QuantType.QInt8,
        )

    normalize_type = model.cfg.preprocessor.normalize
    add_meta_data(
        "encoder.int8.onnx",
        {
            "vocab_size": model.decoder.vocab_size,
            "normalize_type": "" if normalize_type == "NA" else normalize_type,
            "pred_rnn_layers": model.decoder.pred_rnn_layers,
            "pred_hidden": model.decoder.pred_hidden,
            "subsampling_factor": 8,
            "model_type": "EncDecRNNTBPEModel",
            "version": "2",
            "model_author": "NeMo",
            # Same url as the v3 export on purpose: sherpa-onnx reads the
            # model type from this metadata, so it stays what already works.
            "url": "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            "comment": "Weights from moondream/parakeet-ultra, transducer branch only",
            "feat_dim": 128,
        },
    )

    recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder="encoder.int8.onnx",
        decoder="decoder.int8.onnx",
        joiner="joiner.int8.onnx",
        tokens="tokens.txt",
        model_type="nemo_transducer",
    )
    samples, rate = soundfile.read(wav, dtype="float32", always_2d=True)
    stream = recognizer.create_stream()
    stream.accept_waveform(rate, samples[:, 0])
    recognizer.decode_stream(stream)
    onnx_text = stream.result.text.strip()

    print(f"\nv3    (NeMo): {v3_text}\nUltra (NeMo): {ultra_text}\nUltra (int8): {onnx_text}")
    assert ultra_text.strip() and onnx_text, "Empty transcript: the conversion is broken"
    print(f"\nDone: {OUT}/{{encoder,decoder,joiner}}.int8.onnx and tokens.txt")
    print("The fp32 files (encoder.onnx and its weight files) can be deleted.")


if __name__ == "__main__":
    main()
