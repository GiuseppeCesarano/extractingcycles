const std = @import("std");

inline fn pext(input: u64, comptime mask: u64) u64 {
    return asm ("pextq %[mask:P](%%rip), %[src], %[dst]"
        : [dst] "=r" (-> u64),
        : [src] "r" (input),
          [mask] "i" (&mask),
    );
}

// An address is 7-15 chars, so its first 8 chars (head) always hold "A.B." and its last 8 (tail) always hold ".C.D":
// the table has a low half indexed by the head and a high half indexed by the tail. The pext masks keep only bits that
// tell digits from dots, so each half's index says where its dots are: 9 shapes (1-3 digits per octet) among 32 indices.
// An entry is 32 B: a pdep mask spreading the chars over fixed lanes (hundreds, tens, ones, dot per octet), the ascii
// subtracted from them, the per-lane minimum (one more on leading digits, to reject leading zeros) and the half's len.
// The parser requires the two lens to differ by 8 * address.len, so a read that isn't a real entry gets rejected. That
// lets the halves overlap and keeps the table small. After the entries, one adjust table per half caps each digit.
const Table = struct {
    const entries_per_half = 32;

    starts: [2]usize,
    adjust_starts: [2]usize,
    slots: []align(64) const u64,

    // bits 6 and 7 of char 0 are always clear, so the index comes out times 4 for the 32-byte entries
    const head_digit_bits = 0x00101010100010C0;
    const tail_digit_bits = 0x00100010101010C0;

    const Half = enum { high, low };
    const Entry = extern struct { lanes: u64 = 0, ascii: u64 = 0, minimum: u64 = 0, len: u64 = 0 };

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
                std.debug.assert(low_entry.len -% high_entry.len == 8 * address.len);

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
                high_end = 4 * index + 4;
            };
            const low_first = for (entries[low], 0..) |entry, index| {
                if (entry != null) break index;
            } else unreachable;

            var starts: [2]usize = undefined;
            starts[high] = 0;
            starts[low] = high_end - 4 * low_first;
            break :starts starts;
        };

        // Each entry becomes four u64s at its half's start + quadrupled index, followed by the adjust tables. The 3 extra
        // slots are for an unaligned index (non-ASCII first char), which reads up to 3 u64s past the last entry.
        // Result: the final table.
        const adjust_start = starts[low] + 4 * entries_per_half + 3;
        var adjust_starts: [2]usize = undefined;
        adjust_starts[high] = adjust_start;
        adjust_starts[low] = adjust_start + 64;

        const slot_count = adjust_start + 2 * 64;
        const slots: [slot_count]u64 align(64) = slots: {
            // read as either half's len, 4 can't pass the length check
            var slots: [slot_count]u64 = @splat(4);
            for (entries, starts) |array, start| for (array, 0..) |entry, index| {
                if (entry) |value| slots[start + 4 * index ..][0..4].* = .{ value.lanes, value.ascii, value.minimum, value.len };
            };
            slots[adjust_starts[high]..][0..64].* = adjustTable(1);
            slots[adjust_starts[low]..][0..64].* = adjustTable(0);

            break :slots slots;
        };

        // Any pair of reads the parser can make, unaligned and spare indices included, must fail the length check unless
        // both are real entries, or leftover bytes could accept an invalid address.
        // Result: a compile error if one slips.
        const result: Table = .{ .starts = starts, .adjust_starts = adjust_starts, .slots = &slots };
        for (0..4 * entries_per_half) |index_low| for (0..4 * entries_per_half) |index_high| {
            const difference = result.get(.low, index_low).len -% result.get(.high, index_high).len;
            const both_entries = index_low % 4 == 0 and entries[low][index_low / 4] != null and
                index_high % 4 == 0 and entries[high][index_high / 4] != null;
            if (difference % 8 == 0 and difference / 8 >= 7 and difference / 8 <= 15) std.debug.assert(both_entries);
        };

        return result;
    }

    fn placeLane(entry: *Entry, lane: u8, char: u8) void {
        const shift: u6 = @intCast(8 * lane);
        entry.lanes |= @as(u64, 0xFF) << shift;
        entry.ascii |= @as(u64, char) << shift;
        entry.minimum |= @as(u64, char) << shift;
    }

    fn placeOctet(entry: *Entry, hundreds_lane: u8, digits: u8) void {
        const first = hundreds_lane + 3 - digits;
        for (first..hundreds_lane + 3) |lane| placeLane(entry, @intCast(lane), '0');
        if (digits > 1) entry.minimum += @as(u64, 1) << @intCast(8 * first);
    }

    // the difference of the two lens is 8 * address.len
    fn lowEntry(a_digits: u8, b_digits: u8) Entry {
        var entry: Entry = .{};
        placeOctet(&entry, 0, a_digits);
        placeLane(&entry, 3, '.');
        placeOctet(&entry, 4, b_digits);
        placeLane(&entry, 7, '.');
        entry.len = 64 + 8 * (a_digits + 1 + b_digits + 1);
        return entry;
    }

    // the tail is shifted right by len, so it starts at C and the dot before C is gone
    fn highEntry(c_digits: u8, d_digits: u8) Entry {
        var entry: Entry = .{};
        placeOctet(&entry, 1, c_digits);
        placeLane(&entry, 4, '.');
        placeOctet(&entry, 5, d_digits);
        entry.len = 64 - 8 * (c_digits + 1 + d_digits);
        return entry;
    }

    // a hundreds of 2 caps the tens at 5, and a 25 caps the ones at 5
    fn adjustTable(hundreds_lane: u8) [64]u64 {
        var limits: u64 = 0;
        for (0..8) |lane| {
            const maximum: u8 = if (lane % 4 == (hundreds_lane + 3) % 4) 0 else if (lane % 4 == hundreds_lane) 2 else 9;
            limits |= @as(u64, 0x80 - (maximum + 1)) << @intCast(8 * lane);
        }

        var adjust: [64]u64 = undefined;
        for (&adjust, 0..) |*value, index| {
            value.* = limits;
            for (0..2) |octet| {
                const bits = index >> @intCast(3 * octet);
                const tens = 8 * (4 * octet + hundreds_lane + 1);
                if (bits & 1 != 0) value.* += @as(u64, 4) << @intCast(tens);
                if (bits & 7 == 7) value.* += @as(u64, 4) << @intCast(tens + 8);
            }
        }
        return adjust;
    }

    fn set(entries: *[entries_per_half]?Entry, quadrupled_index: usize, entry: Entry) void {
        std.debug.assert(quadrupled_index % 4 == 0);

        const slot = &entries[quadrupled_index / 4];
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

    pub inline fn get(this: *const Table, comptime half: Half, quadrupled_index: usize) Entry {
        return @as(*const Entry, @ptrCast(&this.slots[this.starts[@backingInt(half)] + quadrupled_index])).*;
    }

    pub inline fn getAdjust(this: *const Table, comptime half: Half, index: usize) u64 {
        return this.slots[this.adjust_starts[@backingInt(half)] + index];
    }

    pub inline fn deposit(this: *const Table, comptime half: Half, quadrupled_index: usize, input: u64) u64 {
        return asm (std.fmt.comptimePrint("pdepq {d}(%[base],%[index],8), %[input], %[ret]", .{8 * this.starts[@backingInt(half)]})
            : [ret] "=r" (-> u64),
            : [base] "r" (this.slots.ptr),
              [index] "r" (quadrupled_index),
              [input] "r" (input),
        );
    }
};

const table: Table = .compute();

inline fn parseOctets(comptime half: Table.Half, index: usize, entry: Table.Entry, input: u64) struct { octets: u32, bad: u64 } {
    const adjust_bits, const ones_lanes = switch (half) {
        .low => .{ 0x0000050200000502, 0x00FF000000FF0000 },
        .high => .{ 0x0005020000050200, 0xFF000000FF000000 },
    };

    const chars = table.deposit(half, index, input);
    const digits = chars -% entry.ascii;
    const under_minimum = chars -% entry.minimum;
    const over_maximum = digits +% table.getAdjust(half, pext(digits, adjust_bits));

    const sums = digits *% 0x640A01;
    return .{ .octets = @intCast(pext(sums, ones_lanes)), .bad = (under_minimum | over_maximum) & 0x8080808080808080 };
}

pub inline fn bmiParseIPV4(address: []const u8) !u32 {
    const tail_offset = address.len -% 8;
    const head, const tail = if (tail_offset > 7) try sevenChars(address) else .{
        std.mem.readInt(u64, address[0..8], .little),
        std.mem.readInt(u64, (address.ptr + tail_offset)[0..8], .little),
    };

    const index_low = pext(head, Table.head_digit_bits);
    const index_high = pext(tail, Table.tail_digit_bits);

    const low = table.get(.low, index_low);
    const high = table.get(.high, index_high);

    const parsed_low = parseOctets(.low, index_low, low, head);
    const parsed_high = parseOctets(.high, index_high, high, tail >> @truncate(high.len));

    const bad_len = low.len -% (high.len +% (address.len << 3));
    if ((bad_len | parsed_low.bad | parsed_high.bad) != 0) {
        @branchHint(.cold);
        return error.Invalid;
    }

    return parsed_high.octets << 16 | parsed_low.octets;
}

inline fn sevenChars(address: []const u8) !struct { u64, u64 } {
    if (address.len != 7) return error.Invalid;

    var head: u64 = 0;
    @memcpy(std.mem.asBytes(&head)[0..7], address[0..7]);
    return .{ head, head << 8 };
}
