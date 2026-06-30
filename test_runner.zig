// https://www.openmymind.net/Using-A-Custom-Test-Runner-In-Zig/
// https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b
// Zig 0.17: test functions are accessible via `builtin.test_functions` (type `[]const std.lang.TestFn`).

// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//   .target = target,
//   .optimize = optimize,
//   .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
//   .root_source_file = b.path("src/main.zig"),
// });

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const BORDER = brk: {
    var buf: [80]u8 = undefined;
    for (&buf) |*b| b.* = '=';
    break :brk buf;
};

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const allocator = fba.allocator();

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit(allocator);

    var buffer: [64]u8 = undefined;
    const stderr_lock = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const printer = Printer.init(&stderr_lock.file_writer.interface);
    printer.print("\r\x1b[0K", .{}); // beginning of line and clear to end of line
    printer.print("{s}\n\n", .{BORDER});

    for (builtin.test_functions) |t| {
        var status = Status.pass;
        slowest.startTiming();

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() != 0) {
            leak += 1;
            printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            },
        }

        const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
        printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    printer.print("\n", .{});
    try slowest.display(printer);
    printer.print("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    out: *Io.Writer,

    fn init(w: *Io.Writer) Printer {
        return .{
            .out = w,
        };
    }

    fn print(self: Printer, comptime format: []const u8, args: anytype) void {
        self.out.print(format, args) catch unreachable;
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };
        const out = self.out;
        out.writeAll(color) catch @panic("writeAll failed?!");
        out.print(format, args) catch @panic("print failed?!");
        self.print("\x1b[0m", .{});
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    allocator: Allocator,
    max: usize,
    slowest: SlowestQueue,
    timing_start: Io.Clock.Timestamp,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        var slowest = SlowestQueue.initContext({});
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .allocator = allocator,
            .max = count,
            .slowest = slowest,
            .timing_start = Io.Clock.Timestamp.now(Io.Threaded.global_single_threaded.io(), .awake),
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: Allocator) void {
        self.slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.timing_start = Io.Clock.Timestamp.now(Io.Threaded.global_single_threaded.io(), .awake);
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        const end = Io.Clock.Timestamp.now(Io.Threaded.global_single_threaded.io(), .awake);
        const ns = @as(u96, @intCast(self.timing_start.durationTo(end).raw.nanoseconds));
        const ns_u64 = @as(u64, @intCast(ns));

        const slowest = &self.slowest;

        if (slowest.count() < self.max) {
            slowest.push(self.allocator, TestInfo{ .ns = ns_u64, .name = test_name }) catch @panic("failed to track test timing");
            return ns_u64;
        }

        {
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns_u64) {
                return ns_u64;
            }
        }

        _ = slowest.popMin();
        slowest.push(self.allocator, TestInfo{ .ns = ns_u64, .name = test_name }) catch @panic("failed to track test timing");
        return ns_u64;
    }

    fn display(self: *SlowTracker, printer: Printer) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        printer.print("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            printer.print("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);
