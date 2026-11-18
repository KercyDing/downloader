//! Minimal HTTP download with a vendored CONNECT/TLS proxy fix.

const std = @import("std");

pub const Client = @import("Client.zig");

pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, downloaded: u64, total: u64) void,
};

pub const Options = struct {
    /// Retries after the first attempt.
    retries: u8 = 3,
    retry_delay_ms: u64 = 500,
    max_redirects: u8 = 5,
    /// Overrides HTTP_PROXY/HTTPS_PROXY from `init.environ_map`.
    proxy: ?[]const u8 = null,
    progress: ?Progress = null,
};

/// Downloads `url` to `destination`, retrying failed attempts.
///
/// A failed attempt removes `destination` before the next one. Proxy settings
/// come from `options.proxy`, or else from `init.environ_map`.
pub fn download(
    init: std.process.Init,
    url: []const u8,
    destination: []const u8,
    options: Options,
) !void {
    var attempt: u8 = 0;
    while (true) {
        downloadOnce(init, url, destination, options) catch |err| {
            if (attempt >= options.retries) return err;
            attempt += 1;
            if (options.retry_delay_ms != 0) {
                const delay: i96 = @as(i96, @intCast(options.retry_delay_ms)) * std.time.ns_per_ms;
                std.Io.sleep(init.io, .{ .nanoseconds = delay }, .awake) catch {};
            }
            continue;
        };
        return;
    }
}

fn downloadOnce(
    init: std.process.Init,
    url: []const u8,
    destination: []const u8,
    options: Options,
) !void {
    const io = init.io;
    const allocator = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    if (options.proxy) |proxy_url| {
        const proxy = try createProxy(arena, proxy_url);
        client.http_proxy = proxy;
        client.https_proxy = proxy;
    } else {
        try client.initDefaultProxies(arena, init.environ_map);
    }

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .init(options.max_redirects),
        .headers = .{ .accept_encoding = .omit },
    });
    defer request.deinit();
    try request.sendBodiless();

    var header_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);
    if (response.head.status.class() != .success) return error.HttpStatus;

    const total = response.head.content_length orelse 0;
    if (options.progress) |progress| progress.report(progress.context, 0, total);

    var file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    defer file.close(io);

    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const file_out = &file_writer.interface;

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    var chunk: [64 * 1024]u8 = undefined;
    var downloaded: u64 = 0;
    while (true) {
        const len = try reader.readSliceShort(&chunk);
        if (len == 0) break;
        try file_out.writeAll(chunk[0..len]);
        downloaded += @intCast(len);
        if (options.progress) |progress| progress.report(progress.context, downloaded, total);
    }
    try file_out.flush();
    if (response.head.content_length != null and downloaded != total) {
        return error.IncompleteDownload;
    }
}

fn createProxy(arena: std.mem.Allocator, url: []const u8) !*Client.Proxy {
    const uri = std.Uri.parse(url) catch try std.Uri.parseAfterScheme("http", url);
    const protocol = Client.Protocol.fromUri(uri) orelse return error.UnsupportedProxy;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try std.Io.net.HostName.fromUri(uri, &host_buffer);

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) blk: {
        const value = try arena.alloc(u8, Client.basic_authorization.valueLengthFromUri(uri));
        break :blk Client.basic_authorization.value(uri, value);
    } else null;

    const proxy = try arena.create(Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = .{ .bytes = try arena.dupe(u8, host.bytes) },
        .authorization = authorization,
        .port = uri.port orelse switch (protocol) {
            .plain => 80,
            .tls => 443,
        },
        .supports_connect = true,
    };
    return proxy;
}
