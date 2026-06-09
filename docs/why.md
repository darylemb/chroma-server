# Why this exists

The official `chroma run` server is a thin wrapper around a Rust binary
(`chromadb_rust_bindings.abi3.so`) that exposes a small CLI. On most
platforms it works fine. On some combinations of Linux + aarch64 (e.g.
Oracle Cloud Ampere A1 running Oracle Linux 9) it silently exits with
code 0 and **no log output**, leaving you with no port and no idea
what went wrong.

Reproduction:

```bash
python3 -c "import chromadb.cli.cli; print('ok')"   # works
chroma run --path /tmp/data --port 8000             # exit 0, no log, no port
```

What we know:

- `chromadb.PersistentClient` (embedded mode) works perfectly.
- The Python wrapper's `app()` function delegates everything to the Rust
  binding, so we cannot intercept or fix the bug from the Python side.
- The `Permission denied` errors seen in some systemd setups are a
  separate, secondary issue: `/home` files have SELinux label
  `user_home_t`, and systemd (running as `init_t`) cannot exec them in
  enforcing mode. Moving the binary to `/opt` (label `usr_t`) fixes
  that part.

The pragmatic fix: skip the `chroma run` server entirely and expose the
embedded `PersistentClient` over HTTP via FastAPI. This wrapper is ~140
lines, has fewer moving parts, and adds metrics we actually want.

## Tracking upstream

If you find a real fix for the `chroma run` server on aarch64, please
open an issue at https://github.com/chroma-core/chroma and link it here.
