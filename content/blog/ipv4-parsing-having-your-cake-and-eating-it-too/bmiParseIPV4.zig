const std = @import("std");

fn MaskSymbol(comptime mask: u64) type {
    return struct {
        const name = std.fmt.comptimePrint("ipv4_pext_mask_{x}", .{mask});
        const value: u64 = mask;
        comptime {
            @export(&value, .{ .name = name });
        }
    };
}

inline fn pextConst(input: u64, comptime mask: u64) u64 {
    return asm ("pextq " ++ MaskSymbol(mask).name ++ "(%%rip), %[src], %[dst]"
        : [dst] "=r" (-> u64),
        : [src] "r" (input),
    );
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

fn adjustTable(limits: u64, h_lane: u6) [64]u64 {
    var out: [64]u64 = undefined;
    for (&out, 0..) |*o, i| {
        var adjust: u64 = 0;
        for (0..2) |k| {
            const bits = i >> (3 * k);
            const base = 32 * k + 8 * h_lane;
            if (bits & 1 != 0) adjust |= @as(u64, 4) << (base + 8);
            if (bits & 7 == 7) adjust |= @as(u64, 4) << (base + 16);
        }
        o.* = adjust +% limits;
    }
    return out;
}

inline fn parseTwoTriplets(comptime half: enum { low, high }, chunk: u64, ascii: u64, lead_ones: u64) ParseResult {
    const adjust_table, const index_mask, const value_mask = switch (half) {
        .low => .{ .adjust_low, 0x0000050200000502, 0x00FF000000FF0000 },
        .high => .{ .adjust_high, 0x0005020000050200, 0xFF000000FF000000 },
    };

    const d = chunk -% ascii;
    const dl = d -% lead_ones;

    const index = pextConst(d, index_mask);
    const adjust = lutAdjust(adjust_table, index);

    const err = dl | (d +% adjust);
    const compact = d *% 0x640A01;

    return .{ .value = @intCast(pextConst(compact, value_mask)), .err = err & 0x8080808080808080 };
}

fn leadingOnes(pdep_mask: u64, comptime h_lanes: [2]u6) u64 {
    var ones: u64 = 0;
    for (h_lanes) |h|
        for (h..h + 2) |lane| if ((pdep_mask >> (8 * lane)) & 0xFF != 0) {
            ones |= @as(u64, 1) << (8 * lane);
            break;
        };

    return ones;
}

const lut_size = 64;
const Entry = extern struct { pdep: u64, ascii: u64, lead_ones: u64, len: u64 };
const Tables = extern struct { low: [lut_size]Entry, high: [lut_size]Entry, adjust_low: [lut_size]u64, adjust_high: [lut_size]u64 };

const tables_flat: [@sizeOf(Tables) / 8]u64 align(64) = bt: {
    @setEvalBranchQuota(10_000);

    const adjust_lut_low = adjustTable(0x7F76767D7F76767D, 0);
    const adjust_lut_high = adjustTable(0x76767D7F76767D7F, 1);

    const lut_low = lutl: {
        const every_lane = std.math.maxInt(u64);
        var masks: [lut_size]u64 = @splat(every_lane);
        var lanes: [lut_size]u64 = @splat(0);

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

        // hash yields the inverted dot mask
        var entries: [lut_size]Entry = undefined;
        for (&entries, 0..) |*e, i| {
            const m = masks[i ^ (lut_size - 1)];
            const l = lanes[i ^ (lut_size - 1)];
            e.* = .{ .pdep = m, .ascii = 0x2E3030302E303030 & m, .lead_ones = leadingOnes(m, .{ 0, 4 }), .len = if (l != 0) 8 * (l + 7) else 1 };
        }
        break :lutl entries;
    };

    const lut_high = luth: {
        const every_lane = std.math.maxInt(u64);
        var masks: [lut_size]u64 = @splat(every_lane);
        var shift: [lut_size]u64 = @splat(4);

        // x.x
        masks[40] = 0xFF0000FFFF000000;
        masks[41] = 0xFF0000FFFF000000;
        masks[42] = 0xFF0000FFFF000000;

        // x.xx
        masks[20] = 0xFFFF00FFFF000000;
        masks[21] = 0xFFFF00FFFF000000;

        // x.xxx
        masks[10] = 0xFFFFFFFFFF000000;

        // xx.x
        masks[36] = 0xFF0000FFFFFF0000;
        masks[37] = 0xFF0000FFFFFF0000;

        // xx.xx
        masks[18] = 0xFFFF00FFFFFF0000;

        // xx.xxx
        masks[9] = 0xFFFFFFFFFFFF0000;

        // xxx.x
        masks[34] = 0xFF0000FFFFFFFF00;

        // xxx.xx
        masks[17] = 0xFFFF00FFFFFFFF00;

        // xxx.xxx
        masks[8] = 0xFFFFFFFFFFFFFF00;

        for (&masks, &shift) |p, *s| if (p != every_lane) {
            s.* = 64 - @popCount(p);
        };

        var entries: [lut_size]Entry = undefined;
        for (&entries, 0..) |*e, i| {
            const m = masks[i ^ (lut_size - 1)];
            const s = shift[i ^ (lut_size - 1)];
            e.* = .{ .pdep = m, .ascii = 0x3030302E3030302E & m, .lead_ones = leadingOnes(m, .{ 1, 5 }), .len = s };
        }
        break :luth entries;
    };

    var t: [@sizeOf(Tables) / 8]u64 = undefined;
    const fields: [4][]const u64 = .{ @ptrCast(&lut_low), @ptrCast(&lut_high), &adjust_lut_low, &adjust_lut_high };
    var at: usize = 0;
    for (fields) |f| {
        @memcpy(t[at..][0..f.len], f);
        at += f.len;
    }
    break :bt t;
};

inline fn lutAdjust(comptime field: std.meta.FieldEnum(Tables), index: usize) u64 {
    return tables_flat[@offsetOf(Tables, @tagName(field)) / 8 + index];
}

const tables: *const Tables = @ptrCast(&tables_flat);

inline fn hash(data: u64) usize {
    return @intCast(pextConst(data, 0x0010101010101000));
}

pub inline fn bmiParseIPV4(address: []const u8) !u32 {
    var head: u64 = undefined;
    var tail: u64 = undefined;

    if (address.len < 8) {
        @branchHint(.cold);
        if (address.len != 7) return error.Invalid;
        head = 0;
        @memcpy(std.mem.asBytes(&head)[0..7], address[0..7]);
        tail = head << 8;
    } else {
        @memcpy(std.mem.asBytes(&head), address[0..8]);
        @memcpy(std.mem.asBytes(&tail), (address.ptr + address.len - 8)[0..8]);
    }

    const el = &tables.low[hash(head)];
    const low = parseTwoTriplets(.low, pdep(head, el.pdep), el.ascii, el.lead_ones);

    const eh = &tables.high[hash(tail)];
    const high = parseTwoTriplets(.high, pdep(tail >> @truncate(eh.len), eh.pdep), eh.ascii, eh.lead_ones);

    const bad_len = (el.len -% eh.len) ^ (address.len << 3);
    if ((bad_len | low.err | high.err) != 0) return error.Invalid;

    return high.value << 16 | low.value;
}
