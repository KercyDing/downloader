# downloader

Thin wrapper around Zig 0.17.1's `std.http.Client`, with the CONNECT/TLS proxy fix from [ziglang/zig PR #36484](https://codeberg.org/ziglang/zig/pulls/36484).

## Install

```bash
zig fetch --save git+https://github.com/KercyDing/downloader#main
```

```zig
const downloader = b.dependency("downloader", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("downloader", downloader.module("downloader"));
```

## Usage

```zig
const downloader = @import("downloader");

try downloader.download(init, url, destination, .{
    .retries = 3,
});
```

| Option | Default | Meaning |
| --- | --- | --- |
| `retries` | `3` | Retries after the first attempt. |
| `retry_delay_ms` | `500` | Delay before each retry. |
| `max_redirects` | `5` | Redirect limit. |
| `proxy` | `null` | Overrides proxy environment variables. |
| `progress` | `null` | Called as `report(context, downloaded, total)`. |

Without `proxy`, `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` are read from `init.environ_map`. A failed attempt deletes the partial destination before retrying; parent directories are not created.

## Test

```bash
zig build test
```
