const std = @import("std");
const builtin = @import("builtin");

inline fn pext(input: u64, mask: u64) u64 {
    var ret: u64 = undefined;
    asm volatile ("pextq %[mask], %[src], %[dst]"
        : [dst] "=r" (ret),
        : [src] "r" (input),
          [mask] "r" (mask),
    );
    return ret;
}

// generic, so the name is formatted once per mask rather than per inlined call
fn MaskSymbol(comptime mask: u64) type {
    return struct {
        const name = std.fmt.comptimePrint("ipv4_hybrid_pext_mask_{x}", .{mask});
        const value: u64 = mask;
        comptime {
            @export(&value, .{ .name = name });
        }
    };
}

inline fn pextConst(input: u64, comptime mask: u64) u64 {
    if (builtin.zig_backend != .stage2_llvm) return pext(input, mask);

    return asm ("pextq " ++ MaskSymbol(mask).name ++ "(%%rip), %[src], %[dst]"
        : [dst] "=r" (-> u64),
        : [src] "r" (input),
    );
}

const U8x16 = @Vector(16, u8);

inline fn pshufb(bytes: U8x16, indices: U8x16) U8x16 {
    return asm ("vpshufb %[indices], %[bytes], %[ret]"
        : [ret] "=x" (-> U8x16),
        : [bytes] "x" (bytes),
          [indices] "x" (indices),
    );
}

// bytes unsigned, weights signed
inline fn pmaddubsw(bytes: U8x16, weights: U8x16) @Vector(8, u16) {
    return asm ("vpmaddubsw %[weights], %[bytes], %[ret]"
        : [ret] "=x" (-> @Vector(8, u16)),
        : [bytes] "x" (bytes),
          [weights] "x" (weights),
    );
}

// the 8 bytes at pointer, straight into xmm, so LLVM can't reuse the GPR load
inline fn loadq(pointer: [*]const u8) @Vector(2, u64) {
    return asm ("vmovq (%[pointer]), %[ret]"
        : [ret] "=x" (-> @Vector(2, u64)),
        : [pointer] "r" (pointer),
    );
}

// the 8 bytes at pointer + offset, in both qwords
inline fn broadcastAt(pointer: [*]const u8, offset: usize) @Vector(2, u64) {
    return asm ("vpbroadcastq (%[pointer],%[offset]), %[ret]"
        : [ret] "=x" (-> @Vector(2, u64)),
        : [pointer] "r" (pointer),
          [offset] "r" (offset),
    );
}

// LLVM won't emit vptest here on its own
inline fn anyNonZero(vector: U8x16) bool {
    return 0 != asm ("vptest %[vector], %[vector]"
        : [ret] "={@ccnz}" (-> u8),
        : [vector] "x" (vector),
    );
}

// 8-byte elements at most, so the addressing mode scales the index
const Table = extern struct {
    pattern_low: [size]u64,
    pattern_high: [size]u64,
    sub_low: [size]u64,
    sub_high: [size]u64,
    len_low: [size]u8,
    len_high: [size]u8,

    const size = 64;
    const invalid_len = 0xFF;

    fn compute() Table {
        @setEvalBranchQuota(1_000_000);

        // Per octet, the lanes the shuffle puts its hundreds, tens and ones into, and the dot after
        // it, so that pmaddubsw with weights 100, 0 and 10, 1 gives each octet in two u16s.
        const octet_lanes = [4]struct { digits: [3]usize, dot: ?usize }{
            .{ .digits = .{ 8, 0, 1 }, .dot = 9 },
            .{ .digits = .{ 10, 2, 3 }, .dot = 11 },
            .{ .digits = .{ 12, 4, 5 }, .dot = 13 },
            .{ .digits = .{ 14, 6, 7 }, .dot = null },
        };

        // A lane is valid when (lane - sub) -| (9 -| sub) == 0, so sub = 0 takes any digit,
        // sub = 1 only 1-9, and sub = '.' - '0' exactly a dot.
        const leading_digit_sub = 1;
        const dot_sub: u8 = @as(u8, '.') -% '0';

        // a len no address can match rejects the entry, whatever else it holds
        var table = std.mem.zeroes(Table);
        table.len_low = @splat(invalid_len);
        table.len_high = @splat(invalid_len);

        // every valid address shape: each octet has 1 to 3 digits
        const lengths = [_]u8{ 1, 2, 3 };
        for (lengths) |a_digits| for (lengths) |b_digits| for (lengths) |c_digits| for (lengths) |d_digits| {
            const digits = [4]u8{ a_digits, b_digits, c_digits, d_digits };

            // An example address of that shape, loaded like the parser does. It goes after a zero
            // byte, so a 7-char address's tail starts with 0, as in the cold path.
            var chars: [16]u8 = @splat(0);
            const ones = "111";
            const address = std.fmt.bufPrint(
                chars[1..],
                "{s}.{s}.{s}.{s}",
                .{ ones[0..a_digits], ones[0..b_digits], ones[0..c_digits], ones[0..d_digits] },
            ) catch unreachable;
            const head = chars[1..][0..8].*;
            const tail = chars[1 + address.len - 8 ..][0..8].*;

            // Where each octet starts in the 16 bytes the shuffle reads: a and b in head, which
            // starts with the first char; c and d in tail, which ends with the last char at byte 15.
            const starts = [4]u8{ 0, a_digits + 1, 16 - d_digits - 1 - c_digits, 16 - d_digits };

            // pshufb writes 0 for an index with the top bit set
            var pattern: [16]u8 = @splat(0x80);
            var sub: [16]u8 = @splat(0);
            for (octet_lanes, starts, digits) |lanes, start, digit_count| {
                // right-aligned: the octet's digits go in its last digit_count lanes
                const digit_lanes = lanes.digits[3 - digit_count ..];
                for (digit_lanes, start..) |lane, position| pattern[lane] = position;

                // a 2- or 3-digit octet can't start with 0
                if (digit_count > 1) sub[digit_lanes[0]] = leading_digit_sub;

                const dot_lane = lanes.dot orelse continue;
                pattern[dot_lane] = start + digit_count;
                sub[dot_lane] = dot_sub;
            }

            // each half keeps its own lanes, and the chars it covers: "A.B." and "C.D"
            table.set(.low, hash(head), pattern, sub, a_digits + 1 + b_digits + 1);
            table.set(.high, hash(tail), pattern, sub, c_digits + 1 + d_digits);
        };

        return table;
    }

    // The low half owns lanes 0-3 and 8-11 (octets a and b), the high half 4-7 and 12-15
    // (octets c and d), so each half's share fits in a u64; `interleave` puts it back.
    fn set(table: *Table, comptime half: enum { low, high }, index: usize, pattern: [16]u8, sub: [16]u8, len: u8) void {
        const first_lane = if (half == .low) 0 else 4;
        const own_pattern: u64 = @bitCast(pattern[first_lane..][0..4].* ++ pattern[first_lane + 8 ..][0..4].*);
        const own_sub: u64 = @bitCast(sub[first_lane..][0..4].* ++ sub[first_lane + 8 ..][0..4].*);

        const patterns = &@field(table, "pattern_" ++ @tagName(half));
        const subs = &@field(table, "sub_" ++ @tagName(half));
        const lens = &@field(table, "len_" ++ @tagName(half));

        // addresses whose halves hash the same must need the same entry
        if (lens[index] != invalid_len)
            std.debug.assert(patterns[index] == own_pattern and subs[index] == own_sub and lens[index] == len);

        patterns[index] = own_pattern;
        subs[index] = own_sub;
        lens[index] = len;
    }

    // the parser's hash at comptime: bit i set when bit 4 of char i + 1 is, i.e. when it's a digit
    fn hash(chars: [8]u8) usize {
        var digit_mask: usize = 0;
        for (chars[1..7], 0..) |char, bit| if (char & 0x10 != 0) {
            digit_mask |= @as(usize, 1) << @intCast(bit);
        };
        return digit_mask;
    }

    // through one base pointer, so PIC code needs a single lea for every field
    inline fn get(table: *const Table, comptime field: std.meta.FieldEnum(Table), index: usize) std.meta.Elem(@FieldType(Table, @tagName(field))) {
        const Element = std.meta.Elem(@FieldType(Table, @tagName(field)));
        const base: [*]const u8 = @ptrCast(table);
        const offset = @offsetOf(Table, @tagName(field)) + @sizeOf(Element) * index;
        return @as(*align(1) const Element, @ptrCast(base + offset)).*;
    }
};

const lut: Table align(64) = .compute();

// undoes Table.set's packing: low's dwords to lanes 0-3 and 8-11, high's to 4-7 and 12-15
inline fn interleave(low: u64, high: u64) U8x16 {
    const low_dwords: @Vector(4, u32) = @bitCast(@Vector(2, u64){ low, 0 });
    const high_dwords: @Vector(4, u32) = @bitCast(@Vector(2, u64){ high, 0 });
    return @bitCast(@shuffle(u32, low_dwords, high_dwords, [4]i32{ 0, -1, 1, -2 }));
}

/// Reads exactly the slice.
pub inline fn hybridParseIPV4(address: []const u8) !u32 {
    var head: u64 = undefined;
    var tail: u64 = undefined;
    var head_tail: U8x16 = undefined;

    // also the tail offset, so the range check stays a lea and a cmp
    const tail_offset = address.len -% 8;
    if (tail_offset > 7) {
        @branchHint(.cold);
        if (address.len != 7) return error.Invalid;

        head = 0;
        @memcpy(std.mem.asBytes(&head)[0..7], address[0..7]);
        tail = head << 8;
        head_tail = @bitCast([2]u64{ head, tail });
    } else {
        @memcpy(std.mem.asBytes(&head), address[0..8]);
        @memcpy(std.mem.asBytes(&tail), (address.ptr + tail_offset)[0..8]);

        // from memory: moving head and tail over costs 3 port 5 uops
        head_tail = @bitCast(@shuffle(u64, loadq(address.ptr), broadcastAt(address.ptr, tail_offset), [2]i32{ 0, -2 }));
    }

    // bit 4 is clear for '.' and set for digits
    const digit_bits = 0x0010101010101000;
    const index_low: usize = @intCast(pextConst(head, digit_bits));
    const index_high: usize = @intCast(pextConst(tail, digit_bits));

    const pattern = interleave(lut.get(.pattern_low, index_low), lut.get(.pattern_high, index_high));
    const sub = interleave(lut.get(.sub_low, index_low), lut.get(.sub_high, index_high));

    // saturates to 0 for the dots
    const limit = @as(U8x16, @splat(9)) -| sub;

    const lanes = pshufb(head_tail -% @as(U8x16, @splat('0')), pattern);
    const bad_lanes = (lanes -% sub) -| limit;

    const positional_values: U8x16 = @bitCast([16]i8{ 10, 1, 10, 1, 10, 1, 10, 1, 100, 0, 100, 0, 100, 0, 100, 0 });
    const products = pmaddubsw(lanes, positional_values);
    const hundreds = @shuffle(u16, products, undefined, [8]i32{ 4, 5, 6, 7, undefined, undefined, undefined, undefined });
    const sums = products +% hundreds;
    const high_bytes: @Vector(8, u16) = .{ 0xFF00, 0xFF00, 0xFF00, 0xFF00, 0, 0, 0, 0 };
    const too_big: U8x16 = @bitCast(sums & high_bytes);

    // separate ifs, or LLVM keeps the vptest flag around with setne
    if (address.len -% lut.get(.len_low, index_low) != lut.get(.len_high, index_high)) return error.Invalid;
    if (anyNonZero(bad_lanes | too_big)) {
        @branchHint(.unlikely);
        return error.Invalid;
    }

    const octets: @Vector(8, u8) = @truncate(sums);
    return @truncate(@as(u64, @bitCast(octets)));
}

/// Robert Graham's benchmark API-compatible version
export fn parse_ip_hybrid(buf: [*:0]const u8, max_len: usize, out: *u32) callconv(.c) usize {
    var tail: u64 = undefined;
    @memcpy(std.mem.asBytes(&tail), buf[max_len - 8 .. max_len]);

    const x = tail ^ 0x2020202020202020;
    const has = (x -% 0x0101010101010101) & ~x & 0x8080808080808080;

    const len = 8 + @divFloor(@as(usize, @ctz(has)), 8) - @as(usize, @intFromBool(buf[7] == ' '));

    const result = hybridParseIPV4(buf[0..len :0]) catch return 0;
    out.* = @byteSwap(result);
    return len;
}
