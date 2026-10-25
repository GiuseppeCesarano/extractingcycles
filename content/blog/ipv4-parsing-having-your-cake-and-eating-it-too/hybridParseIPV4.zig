const std = @import("std");
const simd = std.simd;

const U32x4 = @Vector(4, u32);
const U8x16 = @Vector(16, u8);
const I8x16 = @Vector(16, i8);
const U16x8 = @Vector(8, u16);
const U8x8 = @Vector(8, u8);
const U8x4 = @Vector(4, u8);

inline fn pshufb(source: U8x16, pattern: U8x16) U8x16 {
    return asm ("vpshufb %[pattern], %[source], %[ret]"
        : [ret] "=x" (-> U8x16),
        : [source] "x" (source),
          [pattern] "x" (pattern),
    );
}

inline fn weightedPairSums(bytes: U8x16, comptime weights: I8x16) U16x8 {
    var upper_half: U16x8 = undefined;
    return asm (
        \\vpmaddubsw %[weights:P](%%rip), %[bytes], %[sums]
        \\vpshufd $0xee, %[sums], %[upper_half]
        \\vpaddw %[sums], %[upper_half], %[sums]
        : [sums] "=x" (-> U16x8),
          [upper_half] "=x" (upper_half),
        : [bytes] "x" (bytes),
          [weights] "i" (&weights),
    );
}

inline fn anyNonZero(vector: U8x16) bool {
    return @reduce(.Or, vector != @as(U8x16, @splat(0)));
}

inline fn pext(input: u64, comptime mask: u64) u64 {
    return asm ("pextq %[mask:P](%%rip), %[src], %[dst]"
        : [dst] "=r" (-> u64),
        : [src] "r" (input),
          [mask] "i" (&mask),
    );
}

inline fn loadq(pointer: [*]const u8) U8x8 {
    const loaded = asm ("vmovq (%[pointer]), %[ret]"
        : [ret] "=x" (-> U8x16),
        : [pointer] "r" (pointer),
    );
    return simd.extract(loaded, 0, 8);
}

inline fn broadcastAt(pointer: [*]const u8, offset: usize) U8x16 {
    return asm ("vpbroadcastq (%[pointer],%[offset]), %[ret]"
        : [ret] "=x" (-> U8x16),
        : [pointer] "r" (pointer),
          [offset] "r" (offset),
    );
}

// An address is 7-15 chars, so its first 8 chars (head) always hold "A.B." and its last 8 (tail) always hold ".C.D":
// the table has a low half indexed by the head and a high half indexed by the tail. The pext masks keep only bits that
// tell digits from dots, so each half's index says where its dots are: 9 shapes (1-3 digits per octet) among 32 indices.
// An entry is 16 B: a pshufb pattern moving each digit to a fixed lane for pmaddubsw, and a per-lane offset (sub) for the
// range check, 1 on leading digits to reject leading zeros and the dot's value on dot lanes. Byte 7 of the pattern also
// holds the half's share of the address length, in bits pshufb ignores: the parser requires the two shares to add up to
// the real length, so a read that isn't a real entry gets rejected. That lets the halves overlap and keeps the table small.
const Table = struct {
    const entries_per_half = 32;

    starts: [2]usize,
    slots: []align(64) const [8]u8,

    // bit 7 of char 0 is always clear, so the index comes out doubled for the 16-byte entries
    const head_digit_bits = 0x0010101010001080;
    const tail_digit_bits = 0x0010001010101080;

    const Half = enum { high, low };
    // pattern and sub bytes: tens,ones of each octet, then hundreds,dot of each octet
    const Entry = struct { pattern: [8]u8 = @splat(0x80), sub: [8]u8 = @splat(0) };

    fn compute() Table {
        @setEvalBranchQuota(1_000_000);
        const high = @backingInt(Half.high);
        const low = @backingInt(Half.low);

        // One sample address per shape (1-3 digits per octet, 81 shapes), hashed by head and tail like the parser does:
        // octets A.B go to the low half, C.D to the high half. The hash only tells digits from dots, so any digit works;
        // the leading 0 mimics the cold path's 7-char tail.
        // Result: two halves of 32 entries, null where no shape lands.
        const entries = entries: {
            var entries: [2][entries_per_half]?Entry = @splat(@splat(null));

            const lengths = [_]u8{ 1, 2, 3 };
            for (lengths) |a_digits| for (lengths) |b_digits| for (lengths) |c_digits| for (lengths) |d_digits| {
                var chars: [16]u8 = @splat(0);
                const ones = "111";
                const address = std.fmt.bufPrint(chars[1..], "{s}.{s}.{s}.{s}", .{ ones[0..a_digits], ones[0..b_digits], ones[0..c_digits], ones[0..d_digits] }) catch unreachable;

                const low_entry = lowEntry(a_digits, b_digits);
                const high_entry = highEntry(c_digits, d_digits);
                std.debug.assert(lengthSum(low_entry.pattern[7], high_entry.pattern[7]) == address.len);

                set(&entries[low], hash(chars[1..][0..8].*, head_digit_bits), low_entry);
                set(&entries[high], hash(chars[1 + address.len - 8 ..][0..8].*, tail_digit_bits), high_entry);
            };

            break :entries entries;
        };

        // High goes first, low starts right where high's last entry ends, minus its own unused leading indices: those
        // overlap high's entries, harmless since spare indices fail the length check.
        // Result: each half's first slot.
        const starts = starts: {
            var high_end: usize = 0;
            for (entries[high], 0..) |entry, index| if (entry != null) {
                high_end = 2 * index + 2;
            };
            const low_first = for (entries[low], 0..) |entry, index| {
                if (entry != null) break index;
            } else unreachable;

            var starts: [2]usize = undefined;
            starts[high] = 0;
            starts[low] = high_end - 2 * low_first;
            break :starts starts;
        };

        // Each entry becomes two u64s, pattern then sub, at its half's start + doubled index. The extra slot is for an
        // odd index (non-ASCII first char), which reads one u64 past the last entry.
        // Result: the final table.
        const slot_count = starts[low] + 2 * entries_per_half + 1;
        const slots: [slot_count][8]u8 align(64) = slots: {
            var slots: [slot_count][8]u8 = @splat(@splat(0));
            for (entries, starts) |array, start| for (array, 0..) |entry, index| {
                if (entry) |value| slots[start + 2 * index ..][0..2].* = .{ value.pattern, value.sub };
            };

            break :slots slots;
        };

        // Any pair of reads the parser can make, odd and spare indices included, must fail the length check unless both
        // are real entries, or leftover bytes could accept an invalid address.
        // Result: a compile error if one slips.
        const result: Table = .{ .starts = starts, .slots = &slots };
        for (0..2 * entries_per_half) |index_low| for (0..2 * entries_per_half) |index_high| {
            const sum = result.getLength(.low, index_low) +% result.getLength(.high, index_high);
            const both_entries = index_low % 2 == 0 and entries[low][index_low / 2] != null and
                index_high % 2 == 0 and entries[high][index_high / 2] != null;
            if (sum >= 7 and sum <= 15) std.debug.assert(both_entries);
        };

        return result;
    }

    fn placeOctet(entry: *Entry, octet: u8, start: u8, digits: u8, dot: bool) void {
        const digit_lanes = ([3]u8{ 4 + 2 * octet, 2 * octet, 2 * octet + 1 })[3 - digits ..];
        for (digit_lanes, start..) |lane, position| entry.pattern[lane] = @intCast(position);
        if (digits > 1) entry.sub[digit_lanes[0]] = 1;

        const dot_lane = 5 + 2 * octet;
        if (dot) {
            entry.pattern[dot_lane] = start + digits;
            entry.sub[dot_lane] = @as(u8, '.') -% '0';
        }
    }

    fn lowEntry(a_digits: u8, b_digits: u8) Entry {
        var entry: Entry = .{};
        placeOctet(&entry, 0, 0, a_digits, true);
        placeOctet(&entry, 1, a_digits + 1, b_digits, true);
        // byte 7 is B's dot lane, and doubles as the low length share: pshufb ignores the 0x10
        entry.pattern[7] += 0x10;
        return entry;
    }

    fn highEntry(c_digits: u8, d_digits: u8) Entry {
        var entry: Entry = .{};
        // the tail is right-aligned, ending at byte 16 of head_tail
        placeOctet(&entry, 0, 16 - d_digits - 1 - c_digits, c_digits, true);
        placeOctet(&entry, 1, 16 - d_digits, d_digits, false);
        // byte 7 would be D's dot lane, so it holds the high length share instead, negative so pshufb zeroes the lane;
        // with the low's +16, the two shares add up to the address length
        entry.pattern[7] = @bitCast(@as(i8, c_digits + 1 + d_digits) - 15);
        return entry;
    }

    fn set(entries: *[entries_per_half]?Entry, doubled_index: usize, entry: Entry) void {
        std.debug.assert(doubled_index % 2 == 0);

        const slot = &entries[doubled_index / 2];
        if (slot.*) |existing| std.debug.assert(std.meta.eql(existing, entry));
        slot.* = entry;
    }

    fn hash(chars: [8]u8, mask: u64) usize {
        const word: u64 = @bitCast(chars);
        var index: usize = 0;
        var bit: u6 = 0;
        var remaining = mask;
        while (remaining != 0) : (remaining &= remaining - 1) {
            if (word & remaining & -%remaining != 0) index |= 1 << bit;
            bit += 1;
        }
        return index;
    }

    fn lengthSum(low: u8, high: u8) i32 {
        return @as(i32, low) + @as(i8, @bitCast(high));
    }

    pub inline fn get(this: *const Table, comptime half: Half, doubled_index: usize) U32x4 {
        return @as(*align(1) const U32x4, @ptrCast(&this.slots[this.starts[@backingInt(half)] + doubled_index])).*;
    }

    pub inline fn getLength(this: *const Table, comptime half: Half, doubled_index: usize) u64 {
        if (@inComptime()) {
            const share = this.slots[this.starts[@backingInt(half)] + doubled_index][7];
            return if (half == .low) share else @bitCast(@as(i64, @as(i8, @bitCast(share))));
        }

        const extend = if (half == .low) "movzbq" else "movsbq";
        return asm (std.fmt.comptimePrint("{s} {d}(%[base],%[index],8), %[ret]", .{ extend, 8 * this.starts[@backingInt(half)] + 7 })
            : [ret] "=r" (-> u64),
            : [base] "r" (this.slots.ptr),
              [index] "r" (doubled_index),
        );
    }
};

const table: Table = .compute();

pub inline fn hybridParseIPV4(address: []const u8) !u32 {
    const tail_offset = address.len -% 8;
    const head, const tail, const head_tail = if (tail_offset > 7) try sevenChars(address) else .{
        std.mem.readInt(u64, address[0..8], .little),
        std.mem.readInt(u64, (address.ptr + tail_offset)[0..8], .little),
        simd.join(loadq(address.ptr), simd.extract(broadcastAt(address.ptr, tail_offset), 8, 8)),
    };

    const index_low = pext(head, Table.head_digit_bits);
    const index_high = pext(tail, Table.tail_digit_bits);

    if (address.len -% table.getLength(.low, index_low) != table.getLength(.high, index_high)) return error.Invalid;

    // U32x4 so the next interlace is done on 4bytes and not per single byte.
    const low: U32x4 = table.get(.low, index_low);
    const high: U32x4 = table.get(.high, index_high);

    const pattern: U8x16 = @bitCast(simd.interlace(.{ simd.extract(low, 0, 2), simd.extract(high, 0, 2) }));
    const lanes = pshufb(head_tail -% @as(U8x16, @splat('0')), pattern);
    const sums: U16x8 = weightedPairSums(lanes, .{ 10, 1, 10, 1, 10, 1, 10, 1, 100, 0, 100, 0, 100, 0, 100, 0 });

    const high_bytes: U16x8 = .{ 0xFF00, 0xFF00, 0xFF00, 0xFF00, 0, 0, 0, 0 };
    const too_big: U8x16 = @bitCast(sums & high_bytes);

    const sub: U8x16 = @bitCast(simd.interlace(.{ simd.extract(low, 2, 2), simd.extract(high, 2, 2) }));
    const flips: U8x16 = .{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 0xFE, 9, 0xFE, 9, 0xFE, 9, 9 };
    const bad_lanes = (lanes -% sub) -| (sub ^ flips);

    if (anyNonZero(too_big | bad_lanes)) {
        @branchHint(.unlikely);
        return error.Invalid;
    }

    const octets: U8x4 = @intCast(simd.extract(sums, 0, 4));
    return @bitCast(octets);
}

inline fn sevenChars(address: []const u8) !struct { u64, u64, U8x16 } {
    if (address.len != 7) return error.Invalid;

    var head: u64 = 0;
    @memcpy(std.mem.asBytes(&head)[0..7], address[0..7]);
    return .{ head, head << 8, @bitCast([2]u64{ head, head << 8 }) };
}
