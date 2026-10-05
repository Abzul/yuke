//! Codex routing tests drive real HTTP responses, tool execution, retries, and turn boundaries.

const std = @import("std");
const testing = std.testing;
const ai = @import("ai");
const Resources = @import("test_resources.zig");
const toolset = @import("toolset.zig");

const tool_reply = ai.testing.sseFrame(
    \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"search-1","name":"web_search"}}
) ++ ai.testing.sseFrame(
    \\{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{}"}
) ++ ai.testing.sseFrame(
    \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{}"}}
) ++ ai.testing.sseFrame(
    \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
);
const final_reply = ai.testing.sseFrame(
    \\{"type":"response.completed","response":{"status":"completed","usage":{}}}
);

const Peer = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    requests: usize = 0,
    tools_run: usize = 0,
    err: ?anyerror = null,

    fn serve(self: *Peer) void {
        self.exchange() catch |err| {
            self.err = err;
        };
    }

    fn exchange(self: *Peer) !void {
        for (0..4) |index| {
            const stream = try self.listener.accept(self.io);
            defer stream.close(self.io);
            var read_buf: [8192]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            var headers = request.iterateHeaders();
            var routing_headers: usize = 0;
            while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-codex-turn-state")) {
                try testing.expect(index == 1 or index == 2);
                try testing.expectEqualStrings("turn-A", h.value);
                routing_headers += 1;
            };
            try testing.expectEqual(@as(usize, if (index == 1 or index == 2) 1 else 0), routing_headers);
            if (index == 1 or index == 2) try testing.expectEqual(@as(usize, 1), self.tools_run);
            var body_buf: [1024]u8 = undefined;
            _ = try (try request.readerExpectContinue(&body_buf)).discardRemaining();
            try request.respond(if (index == 0) tool_reply else if (index == 1) "" else final_reply, .{
                .status = if (index == 1) .service_unavailable else .ok,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "x-codex-turn-state", .value = if (index == 0) "turn-A" else "must-not-replace-A" },
                },
            });
            self.requests += 1;
        }
    }

    fn search(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
        const self: *Peer = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, name, "web_search"));
        self.tools_run += 1;
        self.io.sleep(.fromMilliseconds(50), .awake) catch return .{ .output = "canceled", .is_error = true };
        return .{ .output = "search result" };
    }
};

test "Codex resumes after a tool and a 503 with the same routing token, but a new turn has none" {
    var f: Resources.Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const io = f.engine.deps.io;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var peer: Peer = .{ .io = io, .listener = &listener };
    var http: ai.transport.HttpTransport = .init(testing.allocator, io, .fromSeconds(5), "codex-test/0");
    defer http.deinit();
    f.engine.deps.route_transport = http.transportFor();
    f.engine.deps.retry_policy = .{ .base_ms = 0, .cap_ms = 0 };
    f.engine.installTools(.{ .ctx = &peer, .decls = Resources.serveTools(&.{"web_search"}), .run = Peer.search });
    f.models[0].protocol = .openai_responses;
    f.rows[0].availability.ready.base_url = try std.fmt.allocPrint(f.arena.allocator(), "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    f.rows[0].availability.ready.endpoints = &.{.{ .protocol = .openai_responses, .responses_dialect = .codex }};
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer _ = server.cancel(io);

    _ = try f.send(&.{.{ .text = .{ .text = "search" } }});
    try f.finish(Resources.Fixture.id);
    try testing.expectEqual(@as(usize, 3), peer.requests);
    const first = try f.history();
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expect(first[2] == .assistant);
    try testing.expect(first[2].assistant.finish == .stop);
    try testing.expect(first[1] == .assistant);
    try testing.expect(first[1].assistant.content[0].tool.state == .completed);

    _ = try f.send(&.{.{ .text = .{ .text = "next turn" } }});
    try f.finish(Resources.Fixture.id);
    server.await(io);
    if (peer.err) |err| return err;
    try testing.expectEqual(@as(usize, 4), peer.requests);
    try testing.expectEqual(@as(usize, 1), peer.tools_run);
    const second = try f.history();
    try testing.expect(second[second.len - 1] == .assistant);
    try testing.expect(second[second.len - 1].assistant.finish == .stop);
}
