const std = @import("std");
const builtin = @import("builtin");
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

fn setupSignalHandlers() void {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        _ = windows.kernel32.SetConsoleCtrlHandler(struct {
            fn handler(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
                _ = ctrl_type;
                c.stop_bluetooth_loop();
                return windows.TRUE;
            }
        }.handler, windows.TRUE);
    } else {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handle_signal },
            .flags = 0,
            .mask = std.mem.zeroes(std.posix.sigset_t),
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
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

    // stdout.print("Received data len: {d}\n", .{slice.len}) catch |err| {
    //     std.debug.print("Failed to write to stdout: {any}\n", .{err});
    // };

    stdout.writeAll(slice) catch |err| {
        std.debug.print("Failed to write to stdout: {any}\n", .{err});
    };
}

pub fn main() !void {
    setupSignalHandlers();

    data_file = try std.fs.cwd().createFile("Raw_data.csv", .{
        .read = true,
        .truncate = false,
    });

    defer data_file.close();

    // check if the file is empty, and if so, write the header
    const file_info = try data_file.stat();
    if (file_info.size == 0) {
        // here the header is just for placeholder
        const header = "\n";
        try data_file.writeAll(header);
    }

    // Move to the end of the file to append new data
    try data_file.seekFromEnd(0);

    c.start_bluetooth_connection(bluetooth_addr, 1, on_data_received);

    try stdout.print("Start appending the header", .{});
    try stdout.flush();

    try cal_and_append_header(data_file);
}

fn cal_and_append_header(file: std.fs.File) !void {
    try file.seekTo(0);

    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&buffer);
    var reader = &file_reader.interface;

    _ = try reader.discardDelimiterInclusive('\n');

    const header = blk: {
        var col_count: usize = 1;
        var header_buf: [1024]u8 = undefined;
        var header_buf_stream = std.io.fixedBufferStream(&header_buf);
        var header_buf_writer = header_buf_stream.writer();

        const data_line = try reader.takeDelimiterExclusive('\n');

        for (data_line) |byte| {
            if (byte == ',') {
                col_count += 1;
            }
        }

        const ppg_count = col_count - 9 - 4;

        try header_buf_writer.print("serial_num,sensor_type,sensor_timestamp,host_monotonic_timestamp,", .{});

        for (0..ppg_count) |i| {
            try header_buf_writer.print("ppg_{d},", .{i});
        }

        try header_buf_writer.print("ax,ay,az,gx,gy,gz,mx,my,mz", .{});

        break :blk header_buf_stream.getWritten();
    };

    try file.seekTo(0);

    _ = try reader.discardDelimiterInclusive('\n');

    const rest_of_file = try file.readToEndAlloc(
        allocator,
        std.math.maxInt(usize),
    );

    defer allocator.free(rest_of_file);

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(header);
    try file.writeAll(rest_of_file);
}
