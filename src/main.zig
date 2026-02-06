const std = @import("std");
const c = @cImport({
    @cInclude("bt_bridge.h");
});

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var allocator = std.heap.page_allocator;

var should_exit = std.atomic.Value(bool).init(false);

var data_file: std.fs.File = undefined;

const bluetooth_addr = "DC:EC:4F:5D:75:D8";

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;

    c.stop_bluetooth_loop();
}

export fn on_data_received(data: [*c]const u8, len: usize) void {
    if (data == null) {
        std.debug.print("Received null data pointer\n", .{});
        return;
    }

    const slice = data[0..len];

    data_file.writeAll(slice) catch |err| {
        std.debug.print("Failed to write data to file: {any}\n", .{err});
        return;
    };

    stdout.print("Received data len: {d}\n", .{slice.len}) catch |err| {
        std.debug.print("Failed to write to stdout: {any}\n", .{err});
    };
}

pub fn main() !void {
    // Set up signal handler
    const act = std.posix.Sigaction{
        .handler = .{
            .handler = handle_signal,
        },
        .flags = 0,
        .mask = std.mem.zeroes(std.posix.sigset_t),
    };

    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    data_file = try std.fs.cwd().createFile("Raw_data.csv", .{
        .read = true,
        .truncate = false,
    });

    defer data_file.close();

    // Move to the end of the file to append new data
    try data_file.seekFromEnd(0);

    c.start_bluetooth_connection(bluetooth_addr, 1, on_data_received);
}
