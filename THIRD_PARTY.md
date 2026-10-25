# Third-party components

Models are downloaded on request, not bundled into the application archive.
Each component retains its original license and notices in the installed runtime.

- [Parakeet MLX](https://github.com/senstella/parakeet-mlx), Apache-2.0.
- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): see the model card and license.
- [MLX model conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3): see the model card.
- [onnx-asr](https://github.com/istupakov/onnx-asr), MIT. Optional adapter for existing NeMo ONNX Parakeet weights.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime), MIT. CPU inference for existing ONNX models.
- [Sherpa ONNX](https://github.com/k2-fsa/sherpa-onnx), Apache-2.0. Segmentation and speaker embeddings: see the upstream release model notices.
- [Ollama](https://github.com/ollama/ollama), MIT. Optional local runtime.
- [Qwen3.5](https://huggingface.co/Qwen/Qwen3.5-9B), Apache-2.0; see the selected model's full model card and license.
- [CPython](https://www.python.org/), Python Software Foundation License. The private installed runtime is embedded by the native Rust speech helper through the public stable ABI; it is not bundled into the app download.
- [uv](https://github.com/astral-sh/uv), Apache-2.0 / MIT.
- [imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg), BSD-2-Clause. The separately downloaded FFmpeg binary retains its upstream licensing.
- [rustup](https://github.com/rust-lang/rustup), Apache-2.0 / MIT. Developer toolchain installer only; the app bundles its compiled Rust worker and does not require Rust on the user's Mac.

The native Rust core's direct dependencies are listed below; exact resolved versions
and transitive dependencies are recorded in `rust-core/Cargo.lock`.

- [anyhow](https://github.com/dtolnay/anyhow), MIT OR Apache-2.0.
- [chrono](https://github.com/chronotope/chrono), MIT OR Apache-2.0.
- [clap](https://github.com/clap-rs/clap), MIT OR Apache-2.0.
- [fsrs 6.6.2](https://github.com/open-spaced-repetition/fsrs-rs), BSD-3-Clause; used without default features.
- [libc](https://github.com/rust-lang/libc), MIT OR Apache-2.0.
- [reqwest 0.12](https://github.com/seanmonstar/reqwest), MIT OR Apache-2.0; blocking, JSON and native TLS support.
- [serde](https://github.com/serde-rs/serde), MIT OR Apache-2.0.
- [sha2](https://github.com/RustCrypto/hashes), MIT OR Apache-2.0.
- [rusqlite](https://github.com/rusqlite/rusqlite), MIT; bundled SQLite (public domain) with FTS5 for the private, rebuildable search index.
- [rust-stemmers](https://github.com/CurrySoftware/rust-stemmers), MIT / BSD-3-Clause; Russian and English word forms for search.
- [unicode-normalization](https://github.com/unicode-rs/unicode-normalization), (MIT OR Apache-2.0) AND Unicode-3.0.
- [serde_json](https://github.com/serde-rs/json), MIT OR Apache-2.0.
- [uuid](https://github.com/uuid-rs/uuid), MIT OR Apache-2.0.

Cloud mode optionally calls the OpenAI API; its terms and billing are separate from this app.
