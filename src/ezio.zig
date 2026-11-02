const std = @import("std");

var io: std.Io = undefined;

pub var stdout: *std.Io.Writer = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stdout_buffer: [1024]u8 = @splat(0);

pub fn initWriters(process_io: std.Io) void {
    io = process_io;
    stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout = &stdout_writer.interface;
}

/// Takes in a formatter and prints it to stdout. Panics if writing fails.
pub fn printfmt(formatter: anytype) void {
    formatter.format(stdout) catch @panic("Printing failed");
    stdout.flush() catch @panic("Printing failed");
}

/// Prints a formatted message to stdout, appending a newline and flushing
/// afterwards.
pub fn println(comptime fmt: []const u8, args: anytype) void {
    stdout.print(fmt, args) catch @panic("Printing failed");
    stdout.writeAll("\n") catch @panic("Printing failed");
    stdout.flush() catch @panic("Printing failed");
}


/// Prints a formatted message to stdout, flushing afterwards.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    stdout.print(fmt, args) catch @panic("Printing failed");
    stdout.flush() catch @panic("Printing failed");
}
