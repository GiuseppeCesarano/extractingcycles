const std = @import("std");
const bmiParseIPV4 = @import("bmi").bmiParseIPV4;
const hybridParseIPV4 = @import("hybrid").hybridParseIPV4;

const AF_INET = std.posix.AF.INET;

extern fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
extern fn bench_simdzone(src: [*:0]const u8, len: usize, out: *u32) callconv(.c) bool;
extern fn bench_simdzone_copy(src: [*:0]const u8, len: usize, out: *u32) callconv(.c) bool;
extern fn bench_simdzone_regs(src: [*:0]const u8, len: usize, out: *u32) callconv(.c) bool;

// Let's use system's strlen and memcpy
extern var strlen_ptr: ?*const fn ([*:0]const u8) callconv(.c) usize;
extern var memcpy_ptr: ?*const fn ([*]u8, [*]const u8, usize) callconv(.c) [*]u8;

fn bmi(src: [*:0]const u8, len: usize, out: *u32) callconv(.c) bool {
    out.* = bmiParseIPV4(src[0..len]) catch return false;
    return true;
}

fn hybrid(src: [*:0]const u8, len: usize, out: *u32) callconv(.c) bool {
    out.* = hybridParseIPV4(src[0..len]) catch return false;
    return true;
}

// From here on the length is ignored: no length, no overread.

fn hybridStrlen(src: [*:0]const u8, _: usize, out: *u32) callconv(.c) bool {
    out.* = hybridParseIPV4(src[0..strlen_ptr.?(src)]) catch return false;
    return true;
}

const with_len = .{
    .{ "bmi (len given)", bmi },
    .{ "simdzone (overreads)", bench_simdzone },
    .{ "hybrid (len given)", hybrid },
};

const no_len = .{
    .{ "hybrid + strlen", hybridStrlen, &strlen_ptr },
    .{ "simdzone + memcpy", bench_simdzone_copy, &memcpy_ptr },
    .{ "simdzone + strlen, regs", bench_simdzone_regs, &strlen_ptr },
};

fn found(comptime parser: anytype) bool {
    return parser.len < 3 or parser[2].* != null;
}

const count = 1_500_000;
const unroll_factor = 4;
const repeat = 64;

const Parse = *const fn ([*:0]const u8, usize, *u32) callconv(.c) bool;

fn benchmark(io: std.Io, comptime name: []const u8, comptime parse: Parse, addrs: []const [:0]const u8, total_len: usize) !void {
    // hide the callee so every parser gets the same call sequence
    var hidden = parse;
    const call = @as(*volatile Parse, &hidden).*;

    const start: std.Io.Timestamp = .now(io, .awake);
    for (0..repeat) |_|
        for (0..count / unroll_factor) |k| inline for (0..unroll_factor) |j| {
            const addr = addrs[k * unroll_factor + j];
            var out: u32 = undefined;
            if (!call(addr.ptr, addr.len, &out)) return error.Invalid;
            std.mem.doNotOptimizeAway(out);
        };
    const end: std.Io.Timestamp = .now(io, .awake);

    const total = end.nanoseconds - start.nanoseconds;
    const ns_per_ip = @as(f64, @floatFromInt(total)) / (count * repeat);
    const gb_per_sec = @as(f64, @floatFromInt(total_len * repeat)) / @as(f64, @floatFromInt(total));

    std.log.info("{s:<24} {d:>6.2} ns/ip {d:>6.2} GB/s", .{ name, ns_per_ip, gb_per_sec });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    strlen_ptr = if (std.c.dlsym(null, "strlen")) |ptr| @ptrCast(ptr) else null;
    memcpy_ptr = if (std.c.dlsym(null, "memcpy")) |ptr| @ptrCast(ptr) else null;

    const bufs = try allocator.alloc([16]u8, count);
    defer allocator.free(bufs);

    const addrs = try allocator.alloc([:0]const u8, count);
    defer allocator.free(addrs);

    var prng: std.Random.DefaultPrng = .init(0x1234_5678_9ABC_DEF0);
    const rand = prng.random();

    var total_len: usize = 0;
    for (bufs, addrs) |*buf, *addr| {
        const ip = rand.int(u32);
        const b = std.mem.asBytes(&ip);
        addr.* = std.fmt.bufPrintSentinel(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }, 0) catch unreachable;
        total_len += addr.len;
    }

    for (addrs) |addr| {
        var want: u32 = undefined;
        if (inet_pton(AF_INET, addr.ptr, &want) != 1) return error.Invalid;
        inline for (with_len ++ no_len) |parser| if (found(parser)) {
            var got: u32 = undefined;
            if (!parser[1](addr.ptr, addr.len, &got) or got != want) {
                std.log.err("{s} disagrees with glibc on {s}", .{ parser[0], addr });
                return error.Mismatch;
            }
        };
    }

    std.log.info("Parsing {d} random IPs {d} times ({d:.2}MB)", .{ count, repeat, @as(f64, @floatFromInt(total_len * repeat)) / (1000 * 1000) });
    inline for (with_len) |p|
        try benchmark(init.io, p[0], p[1], addrs, total_len);

    std.log.info("--- no length, no overread ---", .{});

    inline for (no_len) |p| {
        if (found(p))
            try benchmark(init.io, p[0], p[1], addrs, total_len)
        else
            std.log.info("{s:<24} skipped, libc symbol not found", .{p[0]});
    }
}
