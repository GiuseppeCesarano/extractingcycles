const std = @import("std");
const testing = std.testing;
const bmiParseIPV4 = @import("bmi").bmiParseIPV4;
const hybridParseIPV4 = @import("hybrid").hybridParseIPV4;

extern fn simdzone_inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
extern fn simdzone_regs_inet_pton(src: [*:0]const u8, len: usize, dst: *anyopaque) c_int;

fn padded(address: []const u8, buf: *[64]u8) ![*:0]const u8 {
    if (address.len >= buf.len or std.mem.indexOfScalar(u8, address, 0) != null) return error.Invalid;
    buf.* = @splat(0);
    @memcpy(buf[0..address.len], address);
    return @ptrCast(buf);
}

fn simdzone(address: []const u8) !u32 {
    var buf: [64]u8 = undefined;
    var out: u32 = undefined;
    if (simdzone_inet_pton(std.posix.AF.INET, try padded(address, &buf), &out) != 1) return error.Invalid;
    return out;
}

fn simdzoneRegs(address: []const u8) !u32 {
    var buf: [64]u8 = undefined;
    var out: u32 = undefined;
    if (simdzone_regs_inet_pton(try padded(address, &buf), address.len, &out) != 1) return error.Invalid;
    return out;
}

fn bmi(address: []const u8) !u32 {
    return bmiParseIPV4(address);
}

fn hybrid(address: []const u8) !u32 {
    return hybridParseIPV4(address);
}

const parsers = .{
    .{ "bmi", bmi },
    .{ "hybrid", hybrid },
    .{ "simdzone", simdzone },
    .{ "simdzone regs", simdzoneRegs },
};

fn decimalParse(address: []const u8) ?u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    var digits: u32 = 0;
    var index: u32 = 0;

    for (address) |c| switch (c) {
        '.' => {
            if (digits == 0 or octet > 255 or index >= 3) return null;
            result |= octet << @intCast(8 * index);
            octet = 0;
            digits = 0;
            index += 1;
        },
        '0'...'9' => {
            if (digits == 1 and octet == 0) return null; // leading zero
            octet = octet * 10 + (c - '0');
            digits += 1;
            if (digits > 3) return null;
        },
        else => return null,
    };

    if (digits == 0 or octet > 255 or index != 3) return null;
    result |= octet << 24;
    return result;
}

fn expectAgrees(address: [:0]const u8, expected: ?u32) !void {
    inline for (parsers) |p| {
        const name, const parse = p;
        if (expected) |want| {
            const got = parse(address) catch |err| {
                std.log.err("{s}: rejected \"{s}\" but expected {x:0>8}", .{ name, address, want });
                return err;
            };
            testing.expectEqual(want, got) catch |err| {
                std.log.err("{s}: \"{s}\": got {x:0>8}, expected {x:0>8}", .{ name, address, got, want });
                return err;
            };
        } else if (parse(address)) |got| {
            std.log.err("{s}: accepted \"{s}\" as {x:0>8} but it is invalid", .{ name, address, got });
            return error.ShouldHaveErrored;
        } else |_| {}
    }
}

const Span = struct { start: usize, len: usize };

fn octetSpans(address: []const u8, spans: *[4]Span) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < address.len) {
        if (address[i] == '.') {
            i += 1;
            continue;
        }
        const start = i;
        while (i < address.len and address[i] != '.') i += 1;
        if (n < spans.len) spans[n] = .{ .start = start, .len = i - start };
        n += 1;
    }
    return n;
}

test "known vectors" {
    const cases = [_]struct { addr: [:0]const u8, value: u32 }{
        .{ .addr = "0.0.0.0", .value = 0x00000000 },
        .{ .addr = "255.255.255.255", .value = 0xFFFFFFFF },
        .{ .addr = "1.2.3.4", .value = 0x04030201 },
        .{ .addr = "127.0.0.1", .value = 0x0100007F },
        .{ .addr = "10.0.0.1", .value = 0x0100000A },
        .{ .addr = "192.168.1.1", .value = 0x0101A8C0 },
        .{ .addr = "8.8.8.8", .value = 0x08080808 },
    };

    for (cases) |c| try expectAgrees(c.addr, c.value);
}

test "rejects malformed addresses" {
    const invalid = [_][:0]const u8{
        "256.0.0.0", // octet > 255
        "0.256.0.0",
        "0.0.256.0",
        "0.0.0.256",
        "300.0.0.0",
        "999.999.999.999",
        "12.34.56.789",
        "1234.5.6.7", // four-digit octet
        "1.2.3.4.5", // too many octets
        ".1.2.3.4", // empty octet
        "1..2.3.4",
        "1.2.3.4.", // trailing dot
        "", // too short or too long
        "1.2.3",
        "1.2.34",
        "1.2.3.4.5.6.7.8",
        "255.255.255.2555",
        "1111111111111111111111111",
        "007.0.0.1", // leading zeros
        "10.000.000.1",
        "1.2.3.04",
        "01.2.3.4",
        "282.265.7.97", // tens/ones limits in the xxx.xxx. layout
        "1.2.255.256",
        "1.2.199.260",
    };

    for (invalid) |addr| try expectAgrees(addr, null);
}

test "every canonical address round-trips" {
    var buf: [16]u8 = undefined;

    for (0..std.math.maxInt(u32) + 1) |val| {
        const expected: u32 = @intCast(val);
        const octets = std.mem.asBytes(&expected);
        const addr = std.fmt.bufPrintSentinel(&buf, "{d}.{d}.{d}.{d}", .{
            octets[0], octets[1], octets[2], octets[3],
        }, 0) catch unreachable;

        try expectAgrees(addr, expected);
    }
}

test "rejects non-digit, non-dot bytes" {
    const bases = [_][]const u8{
        "1.2.3.4",
        "1.2.3.45",
        "1.2.34.56",
        "1.23.45.67",
        "12.34.56.78",
        "123.45.67.89",
        "123.145.67.89",
        "123.145.167.89",
        "192.168.1.1",
        "255.255.255.255",
    };
    var buf: [16]u8 = undefined;

    for (bases) |base| for (0..base.len) |pos| {
        for (0..256) |byte| {
            const c: u8 = @intCast(byte);
            if (c == '.' or (c >= '0' and c <= '9')) continue;

            @memcpy(buf[0..base.len], base);
            buf[pos] = c;
            buf[base.len] = 0;
            const addr: [:0]const u8 = buf[0..base.len :0];

            expectAgrees(addr, null) catch |err| {
                std.log.err("byte 0x{x:0>2} at offset {d}", .{ byte, pos });
                return err;
            };
        }
    };
}

test "exhaustive dot placements and leading zeros" {
    var buf: [16]u8 = undefined;

    for (7..16) |len| {
        const num_masks: u32 = @as(u32, 1) << @intCast(len);

        // ascending digits so any lane swap changes the value
        for (0..num_masks) |mask| {
            for (0..len) |i| {
                buf[i] = if ((mask >> @intCast(i)) & 1 == 1) '.' else @as(u8, '1') + @as(u8, @intCast(i % 8));
            }
            buf[len] = 0;
            const addr: [:0]const u8 = buf[0..len :0];

            expectAgrees(addr, decimalParse(addr)) catch |err| {
                std.log.err("len={d} mask={b}", .{ len, mask });
                return err;
            };

            // re-test with a leading zero in each multi-digit octet
            var spans: [4]Span = undefined;
            const count = octetSpans(buf[0..len], &spans);
            for (spans[0..@min(count, spans.len)]) |span| {
                if (span.len < 2) continue;

                var lz: [16]u8 = undefined;
                @memcpy(lz[0..len], buf[0..len]);
                lz[span.start] = '0';
                lz[len] = 0;
                const lz_addr: [:0]const u8 = lz[0..len :0];

                expectAgrees(lz_addr, decimalParse(lz_addr)) catch |err| {
                    std.log.err("len={d} mask={b} leading-zero at offset {d}", .{ len, mask, span.start });
                    return err;
                };
            }
        }
    }
}

test "every octet value 0..999 in every position and layout" {
    const fillers = [_][]const u8{ "7", "25", "1", "99", "255", "200", "256", "199" };
    var buf: [32]u8 = undefined;
    for (0..4) |pos| for (0..1000) |v| for (fillers) |fa| for (fillers) |fb| for (fillers) |fc| {
        const others = [3][]const u8{ fa, fb, fc };
        var parts: [4][]const u8 = undefined;
        var num: [3]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "{d}", .{v}) catch unreachable;
        var oi: usize = 0;
        for (&parts, 0..) |*p, i| {
            if (i == pos) p.* = s else {
                p.* = others[oi];
                oi += 1;
            }
        }
        const addr = std.fmt.bufPrintSentinel(&buf, "{s}.{s}.{s}.{s}", .{ parts[0], parts[1], parts[2], parts[3] }, 0) catch unreachable;
        if (addr.len < 7 or addr.len > 15) continue;
        try expectAgrees(addr, decimalParse(addr));
    };
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    const Weight = testing.Smith.Weight;

    const byte_dist: []const Weight = &.{
        .rangeAtMost(u8, '0', '9', 10),
        .value(u8, '.', 5),
        .rangeAtMost(u8, 0, 255, 1),
    };
    const len_dist: []const Weight = &.{
        .rangeAtMost(u8, 7, 15, 1),
    };

    var buf: [16]u8 = undefined;
    const len = smith.sliceWeighted(&buf, len_dist, byte_dist);
    buf[len] = 0;
    const address = buf[0..len :0];

    try expectAgrees(address, decimalParse(address));
}

test "differential fuzz against decimalParse" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "0.0.0.0",
        "255.255.255.255",
        "127.0.0.1",
        "10.0.0.1",
        "1.2.3.4",
        "192.168.1.1",
        "01.02.03.04",
        "100.200.0.255",
        "999.999.999.999",
        "1.2.3.4.5",
        "1..2.3.4",
        ".1.2.3.4",
        "1.2.3.4.",
        "256.0.0.0",
        "0.0.0.256",
    } });
}
