const std = @import("std");
const bmiParseIPV4 = @import("bmiParseIPV4.zig").bmiParseIPV4;

pub fn main(init: std.process.Init) !void {
    const count = 1_500_000;

    const allocator = init.gpa;

    const bufs = try allocator.alloc([16]u8, count);
    defer allocator.free(bufs);

    const addrs = try allocator.alloc([:0]const u8, count);
    defer allocator.free(addrs);

    var seed: u64 = undefined;
    init.io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
    const rand = prng.random();
    var total_len: usize = 0;
    for (bufs, addrs) |*buf, *addr| {
        const ip = rand.int(u32);
        const b = std.mem.asBytes(&ip);
        addr.* = std.fmt.bufPrintSentinel(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }, 0) catch unreachable;
        total_len += addr.len;
    }

    const unroll_factor = 4;
    const repeat = 64;

    const start: std.Io.Timestamp = .now(init.io, .real);
    for (0..repeat) |_|
        for (0..count / unroll_factor) |k| inline for (0..unroll_factor) |j| std.mem.doNotOptimizeAway(try bmiParseIPV4(addrs[k * unroll_factor + j]));
    const end: std.Io.Timestamp = .now(init.io, .real);

    const total_count = count * repeat;

    const total = end.nanoseconds - start.nanoseconds;
    const ns_per_ip = @as(f64, @floatFromInt(total)) / total_count;

    const size_MB = @as(f64, @floatFromInt(total_len)) / (1000 * 1000) * repeat;
    const size_GB = size_MB / 1000;
    const total_seconds = @as(f64, @floatFromInt(total)) / 1_000_000_000.0;
    const gb_per_sec = if (total_seconds > 0) size_GB / total_seconds else 0.0;

    std.log.info("Parsed {d} random IPs {d} times ({d:.2}MB) in {d} ns", .{ count, repeat, size_MB, total });
    std.log.info("Average latency: {d:.2} ns/ip", .{ns_per_ip});
    std.log.info("Throughput: {d:.2} GB/s", .{gb_per_sec});
}
