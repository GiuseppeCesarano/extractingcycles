const std = @import("std");
const assert = std.debug.assert;

inline fn pext(input: u64, mask: u64) u64 {
    var ret: u64 = undefined;
    asm volatile ("pextq %[mask], %[src], %[dst]"
        : [dst] "=r" (ret),
        : [src] "r" (input),
          [mask] "r" (mask),
    );
    return ret;
}

inline fn pdep(input: u64, mask: u64) u64 {
    var ret: u64 = undefined;
    asm volatile ("pdepq %[mask], %[src], %[dst]"
        : [dst] "=r" (ret),
        : [src] "r" (input),
          [mask] "r" (mask),
    );
    return ret;
}

const ParseResult = struct { value: u32, err: u64 };

const adjust_lut_low = [16]u64{
    0x0000000000000000, 0x0000000000000400, 0x0000000000000000, 0x0000000000040400,
    0x0000040000000000, 0x0000040000000400, 0x0000040000000000, 0x0000040000040400,
    0x0000000000000000, 0x0000000000000400, 0x0000000000000000, 0x0000000000040400,
    0x0004040000000000, 0x0004040000000400, 0x0004040000000000, 0x0004040000040400,
};

inline fn parseTwoTripletsLow(chunk: u64, active_lanes: u64) ParseResult {
    const d = chunk -% (0x2E3030302E303030 & active_lanes);

    const index = pext(d +% 0x00007B7E00007B7E, 0x0000808000008080);
    const adjust = adjust_lut_low[index];

    const err = (d | (d +% 0x7F76767D7F76767D +% adjust)) & 0x8080808080808080;
    const compact = d *% 0x640A01;

    return .{ .value = @intCast(pext(compact, 0x00FF000000FF0000)), .err = err };
}

const adjust_lut_high = [16]u64{
    0x0000000000000000, 0x0000000000040000, 0x0000000000000000, 0x0000000004040000,
    0x0004000000000000, 0x0004000000040000, 0x0004000000000000, 0x0004000004040000,
    0x0000000000000000, 0x0000000000040000, 0x0000000000000000, 0x0000000004040000,
    0x0404000000000000, 0x0404000000040000, 0x0404000000000000, 0x0404000004040000,
};

inline fn parseTwoTripletsHigh(chunk: u64, active_lanes: u64) ParseResult {
    const d = chunk -% (0x3030302E3030302E & active_lanes);

    const index = pext(d +% 0x007B7E00007B7E00, 0x0080800000808000);
    const adjust = adjust_lut_high[index];

    const err = (d | (d +% 0x76767D7F76767D7F +% adjust)) & 0x8080808080808080;
    const compact = d *% 0x640A01;

    return .{ .value = @intCast(pext(compact, 0xFF000000FF000000)), .err = err };
}

const lut_size = 64;
const LutLow = struct { pdep: [lut_size]u64, lanes: [lut_size]u8 };

const lut_low = lutl: {
    const every_lane = std.math.maxInt(u64);
    var masks: [lut_size]u64 = @splat(every_lane);
    var lanes: [lut_size]u8 = @splat(16);

    // x.x
    masks[5] = 0xFFFF0000FFFF0000;
    masks[21] = 0xFFFF0000FFFF0000;
    masks[37] = 0xFFFF0000FFFF0000;

    // x.xx
    masks[9] = 0xFFFFFF00FFFF0000;
    masks[41] = 0xFFFFFF00FFFF0000;

    // x.xxx
    masks[17] = 0xFFFFFFFFFFFF0000;

    // xx.x
    masks[10] = 0xFFFF0000FFFFFF00;
    masks[42] = 0xFFFF0000FFFFFF00;

    // xx.xx
    masks[18] = 0xFFFFFF00FFFFFF00;

    // xx.xxx
    masks[34] = 0xFFFFFFFFFFFFFF00;

    // xxx.x
    masks[20] = 0xFFFF0000FFFFFFFF;

    // xxx.xx
    masks[36] = 0xFFFFFF00FFFFFFFF;

    // xxx.xxx
    masks[4] = 0xFFFFFFFFFFFFFFFF;
    lanes[4] = 9;

    for (&masks, &lanes) |p, *l| l.* = if (p != every_lane) @popCount(p) / 8 + 1 else l.*;

    break :lutl LutLow{ .pdep = masks, .lanes = lanes };
};

const LutHigh = struct { pdep: [64]u64, shift: [64]u8, lanes: [64]u8 };

const lut_high = luth: {
    const every_lane = std.math.maxInt(u64);
    var masks: [lut_size]u64 = @splat(every_lane);
    var shift: [lut_size]u8 = @splat(0);
    var lanes: [lut_size]u8 = @splat(16);

    // x.x
    masks[40] = 0xFF0000FFFF0000FF;
    masks[41] = 0xFF0000FFFF0000FF;
    masks[42] = 0xFF0000FFFF0000FF;

    // x.xx
    masks[20] = 0xFFFF00FFFF0000FF;
    masks[21] = 0xFFFF00FFFF0000FF;

    // x.xxx
    masks[10] = 0xFFFFFFFFFF0000FF;

    // xx.x
    masks[36] = 0xFF0000FFFFFF00FF;
    masks[37] = 0xFF0000FFFFFF00FF;

    // xx.xx
    masks[18] = 0xFFFF00FFFFFF00FF;

    // xx.xxx
    masks[9] = 0xFFFFFFFFFFFF00FF;

    // xxx.x
    masks[34] = 0xFF0000FFFFFFFFFF;

    // xxx.xx
    masks[17] = 0xFFFF00FFFFFFFFFF;

    // xxx.xxx
    masks[8] = 0xFFFFFFFFFFFFFFFF;
    lanes[8] = 6;

    for (&masks, &shift, &lanes) |p, *s, *l| if (p != every_lane) {
        const bits = @popCount(p);
        s.* = 64 - bits;
        l.* = bits / 8 - 2;
    };

    break :luth LutHigh{ .pdep = masks, .shift = shift, .lanes = lanes };
};

inline fn hash(data: u64) usize {
    var h = data ^ 0x2E2E2E2E2E2E2E2E;
    h -%= 0x0101010101010101;
    return @intCast(pext(h, 0x0080808080808000));
}

pub inline fn bmiParseIPV4(address: [:0]const u8) !u32 {
    assert(address.len >= 7 and address.len <= 15);

    var head: u64 = undefined;
    @memcpy(std.mem.asBytes(&head), address[0..8]);

    const index_low = hash(head);
    const low_pdep = lut_low.pdep[index_low];

    const low = parseTwoTripletsLow(pdep(head, low_pdep), low_pdep);

    var tail: u64 = undefined;
    const len_is_7 = address.len == 7;
    const begin = if (len_is_7) 0 else address.len - 8;
    const end = begin + 8;
    @memcpy(std.mem.asBytes(&tail), address[begin..end]);
    tail <<= if (len_is_7) 8 else 0;

    const index_high = hash(tail);
    const high_pdep = lut_high.pdep[index_high];
    const high_shift = lut_high.shift[index_high];

    const high = parseTwoTripletsHigh(pdep(tail >> @intCast(high_shift), high_pdep), high_pdep);

    if ((lut_low.lanes[index_low] + lut_high.lanes[index_high] != address.len) or
        low.err != 0 or high.err != 0)
        return error.Invalid;

    return high.value << 16 | low.value;
}

/// Robert Graham's benchmark API-compatible version
export fn parse_ip_bmi(buf: [*:0]const u8, max_len: usize, out: *u32) callconv(.c) usize {
    var tail: u64 = undefined;
    @memcpy(std.mem.asBytes(&tail), buf[max_len - 8 .. max_len]);

    const x = tail ^ 0x2020202020202020;
    const has = (x -% 0x0101010101010101) & ~x & 0x8080808080808080;

    const len = 8 + @divFloor(@as(usize, @ctz(has)), 8) - @as(usize, @intFromBool(buf[7] == ' '));

    const result = bmiParseIPV4(buf[0..len :0]) catch return 0;
    out.* = @byteSwap(result);
    return len;
}

const testing = std.testing;

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
    if (expected) |want| {
        const got = bmiParseIPV4(address) catch |err| {
            std.log.err("rejected \"{s}\" but expected {x:0>8}", .{ address, want });
            return err;
        };
        testing.expectEqual(want, got) catch |err| {
            std.log.err("\"{s}\": got {x:0>8}, expected {x:0>8}", .{ address, got, want });
            return err;
        };
    } else if (bmiParseIPV4(address)) |got| {
        std.log.err("accepted \"{s}\" as {x:0>8} but it is invalid", .{ address, got });
        return error.ShouldHaveErrored;
    } else |_| {}
}

const Span = struct { start: usize, len: usize };

// Returns the true octet count, which can exceed four for malformed input.
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
        // leading zeros are decimal, not octal
        .{ .addr = "007.0.0.1", .value = 0x01000007 },
        .{ .addr = "10.000.000.1", .value = 0x0100000A },
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
    };

    for (invalid) |addr| testing.expectError(error.Invalid, bmiParseIPV4(addr)) catch |err| {
        std.log.err("expected \"{s}\" to be rejected", .{addr});
        return err;
    };
}

test "every canonical address round-trips" {
    var buf: [16]u8 = undefined;

    for (0..std.math.maxInt(u32) + 1) |val| {
        const expected: u32 = @intCast(val);
        const octets = std.mem.asBytes(&expected);
        const addr = std.fmt.bufPrintSentinel(&buf, "{d}.{d}.{d}.{d}", .{
            octets[0], octets[1], octets[2], octets[3],
        }, 0) catch unreachable;

        const got = bmiParseIPV4(addr) catch |err| {
            std.log.err("rejected valid address \"{s}\"", .{addr});
            return err;
        };
        testing.expectEqual(expected, got) catch |err| {
            const got_octets = std.mem.asBytes(&got);
            std.log.err("\"{s}\": got {d}.{d}.{d}.{d}", .{
                addr, got_octets[0], got_octets[1], got_octets[2], got_octets[3],
            });
            return err;
        };
    }
}

test "rejects non-digit, non-dot bytes" {
    const base = "192.168.1.1";
    var buf: [16]u8 = undefined;

    for (0..base.len) |pos| {
        for (0..256) |byte| {
            const c: u8 = @intCast(byte);
            if (c == '.' or (c >= '0' and c <= '9')) continue;

            @memcpy(buf[0..base.len], base);
            buf[pos] = c;
            buf[base.len] = 0;
            const addr: [:0]const u8 = buf[0..base.len :0];

            testing.expectError(error.Invalid, bmiParseIPV4(addr)) catch |err| {
                std.log.err("\"{s}\" with byte 0x{x:0>2} at offset {d} was not rejected", .{ addr, byte, pos });
                return err;
            };
        }
    }
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
