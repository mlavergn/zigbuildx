const std = @import("std");
const log = std.log.scoped(.zigbuildx_docs_server);
const builtin = @import("builtin");

/// Serves an autodoc site on loopback, for `Docs.addServe`.
///
/// Autodoc's front end fetches `main.wasm` and `sources.tar`, which a page
/// opened from `file://` cannot do, so the site needs an HTTP server; this one
/// stands in for a `python3 -m http.server` the host may not have. It serves
/// one directory, answers GET and HEAD with one response per connection, and
/// never decodes a request's path, so no request can name a file outside it.
pub const DocsServer = struct {
    const Self = @This();

    /// Loopback only: the docs are for the person at this machine.
    pub const host = "127.0.0.1";

    /// The size of each connection's read and write buffers.
    const buffer_size = 16 * 1024;

    /// Allocates each response's body.
    allocator: std.mem.Allocator,
    /// The listening socket and its streams.
    io: std.Io,
    /// The site's directory; owned by the caller.
    root: std.Io.Dir,
    /// Where to listen; port 0 lets the OS pick one.
    address: std.Io.net.IpAddress,

    /// Returns a server for the site in `root`, not yet listening.
    ///
    /// - `allocator`: Allocates each response's body.
    /// - `io`: The listening socket and its streams.
    /// - `root`: The site's directory, open; the caller closes it after `run`.
    /// - `port`: The port, or 0 for one the OS picks.
    /// - Returns: The server; `error.InvalidIpAddress` cannot happen for `host`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, port: u16) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .address = try std.Io.net.IpAddress.parse(host, port),
        };
    }

    /// `zigbuildx docs-serve <dir> [port]`: serves the autodoc site at `dir`.
    ///
    /// - `process_init`: The process's allocator and IO.
    /// - `args`: The command line after the program's path; `args[0]` is the command.
    /// - Returns: `error.InvalidArguments`, IO errors, or network errors.
    pub fn command(process_init: std.process.Init, args: []const [:0]const u8) !void {
        const io = process_init.io;
        if (args.len < 2 or args.len > 3) {
            log.err("usage: zigbuildx docs-serve <dir> [port]", .{});
            return error.InvalidArguments;
        }
        const port: u16 = if (args.len == 3) std.fmt.parseInt(u16, args[2], 10) catch {
            log.err("docs-serve: '{s}' is not a port", .{args[2]});
            return error.InvalidArguments;
        } else 0;

        var root = try std.Io.Dir.cwd().openDir(io, args[1], .{});
        defer root.close(io);

        var buffer: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
        const server = try Self.init(process_init.gpa, io, root, port);
        try server.run(&stdout.interface);
    }

    /// Serves the site until the process is stopped, printing its URL to `writer` and opening it in the browser.
    ///
    /// - `self`: The server.
    /// - `writer`: Where the URL goes; flushed before serving.
    /// - Returns: Network errors from binding, or `writer`'s errors.
    pub fn run(self: *const Self, writer: *std.Io.Writer) !void {
        var listener = try self.address.listen(self.io, .{ .reuse_address = true });
        defer listener.deinit(self.io);

        const url = try self.allocator.print("http://{f}/", .{listener.socket.address});
        defer self.allocator.free(url);
        try writer.print("docs at {s} (Ctrl-C to stop)\n", .{url});
        try writer.flush();

        // Only once the socket is bound, so the browser cannot beat it there.
        self.openInBrowser(url);

        while (true) {
            const stream = listener.accept(self.io) catch |err| {
                log.err("accept failed [{t}]", .{err});
                continue;
            };
            defer stream.close(self.io);
            self.serveConnection(stream) catch |err| log.warn("request failed [{t}]", .{err});
        }
    }

    /// Returns the file a request target names, relative to the site; anything that could leave it is refused.
    ///
    /// - `target`: The request target, `/path?query`.
    /// - Returns: The relative path, `index.html` for `/`; null when refused.
    pub fn sitePath(target: []const u8) ?[]const u8 {
        const end = std.mem.findAny(u8, target, "?#") orelse target.len;
        const path = target[0..end];
        if (path.len == 0 or path[0] != '/') return null;
        const relative = path[1..];
        if (relative.len == 0) return "index.html";
        // Never percent-decoded, so `%2e%2e` names a file of that name; an absolute path (`//etc`), a backslash and a drive's colon are refused.
        if (relative[0] == '/' or std.mem.findAny(u8, relative, "\\:") != null) return null;
        var parts = std.mem.splitScalar(u8, relative, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return null;
        }
        return relative;
    }

    /// Returns the `content-type` for a file, by its extension.
    ///
    /// - `path`: The file's path.
    /// - Returns: The media type, `application/octet-stream` when the extension is unknown.
    pub fn contentType(path: []const u8) []const u8 {
        const types = [_][2][]const u8{
            .{ ".html", "text/html; charset=utf-8" },
            .{ ".js", "text/javascript; charset=utf-8" },
            .{ ".css", "text/css; charset=utf-8" },
            // Browsers compile a module streamed under any other type only by falling back.
            .{ ".wasm", "application/wasm" },
            .{ ".tar", "application/x-tar" },
            .{ ".json", "application/json" },
            .{ ".svg", "image/svg+xml" },
            .{ ".png", "image/png" },
        };
        for (types) |entry| {
            if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
        }
        return "application/octet-stream";
    }

    /// Answers the one request on `stream`; the caller closes it.
    ///
    /// - `self`: The server.
    /// - `stream`: The accepted connection.
    /// - Returns: Request and response failures.
    fn serveConnection(self: *const Self, stream: std.Io.net.Stream) !void {
        var read_buffer: [buffer_size]u8 = undefined;
        var write_buffer: [buffer_size]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch |err| switch (err) {
            // A browser opening a speculative connection and closing it is routine.
            error.HttpConnectionClosing => return,
            else => return err,
        };

        if (request.head.method != .GET and request.head.method != .HEAD) {
            return request.respond("method not allowed\n", .{ .status = .method_not_allowed, .keep_alive = false });
        }
        const path = Self.sitePath(request.head.target) orelse {
            return request.respond("bad request\n", .{ .status = .bad_request, .keep_alive = false });
        };
        const body = self.root.readFileAlloc(self.io, path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => {
                return request.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
            },
            else => return err,
        };
        defer self.allocator.free(body);

        try request.respond(body, .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = Self.contentType(path) }},
        });
    }

    /// Opens `url` in the system browser; a failure is only logged.
    ///
    /// - `self`: The server.
    /// - `url`: The site's address.
    fn openInBrowser(self: *const Self, url: []const u8) void {
        // A headless host has no browser, and the printed URL is enough.
        const argv: []const []const u8 = switch (builtin.os.tag) {
            .macos => &.{ "open", url },
            .windows => &.{ "cmd", "/c", "start", "", url },
            else => &.{ "xdg-open", url },
        };
        var child = std.process.spawn(self.io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore }) catch |err| {
            log.warn("cannot open a browser for {s} [{t}]", .{ url, err });
            return;
        };
        // The launcher exits once it has handed the URL off; waiting reaps it.
        _ = child.wait(self.io) catch |err| log.warn("browser launcher failed [{t}]", .{err});
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "sitePath maps the root to index.html and strips the query" {
    try std.testing.expectEqualStrings("index.html", DocsServer.sitePath("/").?);
    try std.testing.expectEqualStrings("index.html", DocsServer.sitePath("/?a=b").?);
    try std.testing.expectEqualStrings("main.wasm", DocsServer.sitePath("/main.wasm").?);
    try std.testing.expectEqualStrings("a/b.js", DocsServer.sitePath("/a/b.js#x").?);
}

test "sitePath refuses anything that could leave the site" {
    const refused = [_][]const u8{ "", "main.js", "//etc/passwd", "/../x", "/a/../../x", "/..", "/a\\b", "/C:/x" };
    for (refused) |target| try std.testing.expectEqual(null, DocsServer.sitePath(target));
    // Never decoded, so this names a file called `%2e%2e`, inside the site.
    try std.testing.expectEqualStrings("%2e%2e/x", DocsServer.sitePath("/%2e%2e/x").?);
}

test "contentType serves wasm as application/wasm" {
    try std.testing.expectEqualStrings("application/wasm", DocsServer.contentType("main.wasm"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", DocsServer.contentType("index.html"));
    try std.testing.expectEqualStrings("application/octet-stream", DocsServer.contentType("README"));
}
