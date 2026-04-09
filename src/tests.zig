const std = @import("std");
const SharedString = @import("shared_string.zig").SharedString;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Basic create/read/release tests
// ---------------------------------------------------------------------------

test "SharedString: basic create and read" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.init(allocator, "hello");
    defer ref.release(allocator);

    try testing.expectEqualStrings("hello", ref.slice());
    try testing.expectEqual(@as(usize, 5), ref.len());
}

test "SharedString: empty string" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.init(allocator, "");
    defer ref.release(allocator);

    try testing.expectEqualStrings("", ref.slice());
    try testing.expectEqual(@as(usize, 0), ref.len());
}

test "SharedString: retain shares allocation, both release safely" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "world");
    const b = a.retain();

    // Same underlying allocation.
    try testing.expectEqual(a.ptr, b.ptr);
    try testing.expectEqualStrings("world", a.slice());
    try testing.expectEqualStrings("world", b.slice());

    a.release(allocator);
    // b still alive; bytes still valid.
    try testing.expectEqualStrings("world", b.slice());
    b.release(allocator);
    // allocation freed here — DebugAllocator confirms no leak.
}

test "SharedString: strong count reaches zero exactly once" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "refcount");
    const b = a.retain();
    const c = b.retain();

    try testing.expectEqual(@as(usize, 3), a.strongCount());
    c.release(allocator);
    try testing.expectEqual(@as(usize, 2), a.strongCount());
    b.release(allocator);
    try testing.expectEqual(@as(usize, 1), a.strongCount());
    a.release(allocator); // frees allocation
}

test "SharedString: slice pointer stability across retains" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "stable");
    const b = a.retain();

    // Both Refs point to the same bytes.
    try testing.expectEqual(a.slice().ptr, b.slice().ptr);

    b.release(allocator);
    a.release(allocator);
}

test "SharedString: fused allocation — header and bytes are contiguous" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.init(allocator, "fused");
    defer ref.release(allocator);

    const header_end = @intFromPtr(ref.ptr) + @sizeOf(SharedString);
    const bytes_start = @intFromPtr(ref.slice().ptr);
    try testing.expectEqual(header_end, bytes_start);
}

// ---------------------------------------------------------------------------
// Mutation tests (in-place vs CoW)
// ---------------------------------------------------------------------------

test "SharedString: mutate in-place when exclusive and fits" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var ref = try SharedString.Ref.init(allocator, "hello");
    defer ref.release(allocator);

    const original_ptr = ref.ptr;
    try ref.mutate(allocator, "world");

    // In-place: same header allocation.
    try testing.expectEqual(original_ptr, ref.ptr);
    try testing.expectEqualStrings("world", ref.slice());
}

test "SharedString: mutate CoW when shared" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var a = try SharedString.Ref.init(allocator, "shared");
    const b = a.retain();
    defer b.release(allocator);

    const original_ptr = a.ptr;
    try a.mutate(allocator, "private");
    defer a.release(allocator);

    // CoW: a got a new allocation.
    try testing.expect(a.ptr != original_ptr);
    try testing.expectEqualStrings("private", a.slice());
    // b still sees original.
    try testing.expectEqualStrings("shared", b.slice());
}

test "SharedString: mutate CoW when new content is larger" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var ref = try SharedString.Ref.init(allocator, "hi");
    const original_ptr = ref.ptr;
    try ref.mutate(allocator, "much longer string here");
    defer ref.release(allocator);

    // New allocation required (content doesn't fit).
    try testing.expect(ref.ptr != original_ptr);
    try testing.expectEqualStrings("much longer string here", ref.slice());
}

test "SharedString: mutate in-place zero-pads tail" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    // Allocate with long content so the header's allocation is large.
    var ref = try SharedString.Ref.init(allocator, "long string");
    defer ref.release(allocator);

    try ref.mutate(allocator, "short");
    try testing.expectEqualStrings("short", ref.slice());
    // The tail bytes (indices 5–10) must be zero.
    const bp = ref.ptr.bytesPtr();
    for (5..11) |i| {
        try testing.expectEqual(@as(u8, 0), bp[i]);
    }
}

test "SharedString: mutate to empty string" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var ref = try SharedString.Ref.init(allocator, "nonempty");
    defer ref.release(allocator);

    try ref.mutate(allocator, "");
    try testing.expectEqualStrings("", ref.slice());
    try testing.expectEqual(@as(usize, 0), ref.len());
}

// ---------------------------------------------------------------------------
// String format and utility tests
// ---------------------------------------------------------------------------

test "SharedString: sliceZ is NUL-terminated" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.init(allocator, "hello");
    defer ref.release(allocator);

    const z = ref.sliceZ();
    try testing.expectEqualStrings("hello", z);
    // Sentinel byte at [len] is 0.
    try testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
}

test "SharedString: sliceZ remains valid after in-place mutate" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var ref = try SharedString.Ref.initCapacity(allocator, "hi", 16);
    defer ref.release(allocator);

    try ref.mutate(allocator, "bigger!");
    const z = ref.sliceZ();
    try testing.expectEqualStrings("bigger!", z);
    try testing.expectEqual(@as(u8, 0), z.ptr[z.len]);

    try ref.mutate(allocator, "x");
    const z2 = ref.sliceZ();
    try testing.expectEqualStrings("x", z2);
    try testing.expectEqual(@as(u8, 0), z2.ptr[z2.len]);
}

test "SharedString: initCapacity reserves headroom, avoids CoW on grow" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var ref = try SharedString.Ref.initCapacity(allocator, "hi", 32);
    defer ref.release(allocator);
    const original_ptr = ref.ptr;
    try testing.expectEqual(@as(u32, 32), ref.ptr.cap);
    try testing.expectEqual(@as(u32, 2), ref.ptr.len);

    try ref.mutate(allocator, "this fits in thirty-two bytes!!!");
    try testing.expectEqual(original_ptr, ref.ptr); // in-place, no CoW
    try testing.expectEqualStrings("this fits in thirty-two bytes!!!", ref.slice());
}

test "SharedString: initCapacity with min_capacity < str.len uses str.len" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.initCapacity(allocator, "longer string", 3);
    defer ref.release(allocator);
    try testing.expectEqual(@as(u32, 13), ref.ptr.cap);
    try testing.expectEqualStrings("longer string", ref.slice());
}

test "SharedString: eql, eqlSlice, order" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "apple");
    defer a.release(allocator);
    const b = try SharedString.Ref.init(allocator, "apple");
    defer b.release(allocator);
    const c = try SharedString.Ref.init(allocator, "banana");
    defer c.release(allocator);
    const a_alias = a.retain();
    defer a_alias.release(allocator);

    // Content equality across distinct allocations.
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    // Same-allocation fast path.
    try testing.expect(a.eql(a_alias));
    // Raw-slice comparison.
    try testing.expect(a.eqlSlice("apple"));
    try testing.expect(!a.eqlSlice("APPLE"));
    // Ordering.
    try testing.expectEqual(std.math.Order.lt, a.order(c));
    try testing.expectEqual(std.math.Order.gt, c.order(a));
    try testing.expectEqual(std.math.Order.eq, a.order(b));
    try testing.expectEqual(std.math.Order.eq, a.order(a_alias));
}

test "SharedString: hash is content-based" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "key");
    defer a.release(allocator);
    const b = try SharedString.Ref.init(allocator, "key");
    defer b.release(allocator);
    const c = try SharedString.Ref.init(allocator, "different");
    defer c.release(allocator);

    try testing.expectEqual(a.hash(), b.hash());
    try testing.expect(a.hash() != c.hash());
    // Matches raw std.hash.Wyhash of the slice.
    try testing.expectEqual(std.hash.Wyhash.hash(0, "key"), a.hash());
}

test "SharedString: format prints contents" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const ref = try SharedString.Ref.init(allocator, "hello world");
    defer ref.release(allocator);

    const rendered = try std.fmt.allocPrint(allocator, "<{f}>", .{ref});
    defer allocator.free(rendered);
    try testing.expectEqualStrings("<hello world>", rendered);
}

test "SharedString: HashContext usable with std.HashMap" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var map = std.HashMap(
        SharedString.Ref,
        u32,
        SharedString.Ref.HashContext,
        std.hash_map.default_max_load_percentage,
    ).init(allocator);
    defer {
        var it = map.keyIterator();
        while (it.next()) |k| k.release(allocator);
        map.deinit();
    }

    const k1 = try SharedString.Ref.init(allocator, "alpha");
    try map.put(k1, 1);
    const k2 = try SharedString.Ref.init(allocator, "beta");
    try map.put(k2, 2);

    // Lookup with a distinct allocation having the same content.
    const probe = try SharedString.Ref.init(allocator, "alpha");
    defer probe.release(allocator);
    try testing.expectEqual(@as(?u32, 1), map.get(probe));

    const probe2 = try SharedString.Ref.init(allocator, "gamma");
    defer probe2.release(allocator);
    try testing.expectEqual(@as(?u32, null), map.get(probe2));
}

test "SharedString: mutate grow-after-shrink reuses capacity" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    // Start with cap = len = 11.
    var ref = try SharedString.Ref.init(allocator, "eleven char");
    defer ref.release(allocator);
    const original_ptr = ref.ptr;
    try testing.expectEqual(@as(u32, 11), ref.ptr.cap);

    // Shrink to 5: in-place, cap unchanged.
    try ref.mutate(allocator, "short");
    try testing.expectEqual(original_ptr, ref.ptr);
    try testing.expectEqual(@as(u32, 11), ref.ptr.cap);
    try testing.expectEqual(@as(u32, 5), ref.ptr.len);

    // Grow back to 8: must still be in-place (8 <= cap=11).
    // Previous buggy impl would CoW here because 8 > len=5.
    try ref.mutate(allocator, "eightchr");
    try testing.expectEqual(original_ptr, ref.ptr);
    try testing.expectEqualStrings("eightchr", ref.slice());
    try testing.expectEqual(@as(u32, 11), ref.ptr.cap);

    // Grow to exactly cap: still in-place.
    try ref.mutate(allocator, "01234567890"[0..11]);
    try testing.expectEqual(original_ptr, ref.ptr);
    try testing.expectEqualStrings("01234567890", ref.slice());

    // Exceed cap: CoW.
    try ref.mutate(allocator, "twelve chars");
    try testing.expect(ref.ptr != original_ptr);
    try testing.expectEqualStrings("twelve chars", ref.slice());
}

// ---------------------------------------------------------------------------
// Weak / unwrap / managed tests
// ---------------------------------------------------------------------------

test "SharedString: weak ref basic lifecycle" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "weakly-held");
    const weak = strong.downgrade();

    // A fresh Weak means 1 user weak + 1 ghost = raw 2; user sees 1.
    try testing.expectEqual(@as(usize, 1), strong.strongCount());
    try testing.expectEqual(@as(usize, 1), strong.weakCount());

    // Drop the only strong ref — content should be dead, allocation alive.
    strong.release(allocator);
    try testing.expectEqual(@as(usize, 0), weak.strongCount());
    // Ghost was released; now just the user weak.
    try testing.expectEqual(@as(usize, 1), weak.weakCount());

    // Upgrade after strong death must return null.
    try testing.expect(weak.upgrade(allocator) == null);

    // Releasing the last Weak frees the allocation.
    weak.release(allocator);
}

test "SharedString: upgrade while strong alive returns valid Ref" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "upgradeable");
    defer strong.release(allocator);
    const weak = strong.downgrade();
    defer weak.release(allocator);

    const upgraded = weak.upgrade(allocator) orelse return error.TestUpgradeFailed;
    defer upgraded.release(allocator);
    try testing.expectEqual(strong.ptr, upgraded.ptr);
    try testing.expectEqualStrings("upgradeable", upgraded.slice());
    try testing.expectEqual(@as(usize, 2), strong.strongCount());
    try testing.expectEqual(@as(usize, 1), strong.weakCount());
}

test "SharedString: weakCount excludes the ghost ref" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "ghost");
    defer strong.release(allocator);

    try testing.expectEqual(@as(usize, 0), strong.weakCount());

    const w1 = strong.downgrade();
    try testing.expectEqual(@as(usize, 1), strong.weakCount());
    const w2 = strong.downgrade();
    try testing.expectEqual(@as(usize, 2), strong.weakCount());
    const w3 = w2.retain();
    try testing.expectEqual(@as(usize, 3), strong.weakCount());

    w3.release(allocator);
    w2.release(allocator);
    w1.release(allocator);
    try testing.expectEqual(@as(usize, 0), strong.weakCount());
}

test "SharedString: allocation lives until last weak is released" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "outlive");
    const w1 = strong.downgrade();
    const w2 = strong.downgrade();

    strong.release(allocator);
    // Allocation still live (w1 & w2 outstanding). Strong count is 0.
    try testing.expectEqual(@as(usize, 0), w1.strongCount());
    try testing.expect(w1.upgrade(allocator) == null);

    w1.release(allocator);
    // Still alive (w2 holds it).
    try testing.expectEqual(@as(usize, 0), w2.strongCount());

    w2.release(allocator); // frees allocation — DebugAllocator confirms no leak.
}

test "SharedString: bytes are zeroed when strong_count hits zero" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "secretish");
    const weak = strong.downgrade();

    // Before: bytes readable.
    try testing.expectEqualStrings("secretish", strong.slice());

    const cap = strong.ptr.cap;
    strong.release(allocator);

    // Access via Weak's raw header pointer (allocation still live).
    // Same-file test can call private bytesPtr().
    const bp = weak.ptr.bytesPtr();
    var i: usize = 0;
    while (i <= cap) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), bp[i]);
    }
    weak.release(allocator);
}

test "SharedString: tryUnwrap returns null when shared" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "shared-try");
    defer a.release(allocator);
    const b = a.retain();
    defer b.release(allocator);

    const result = try a.tryUnwrap(allocator);
    try testing.expect(result == null);
    // Both refs still valid.
    try testing.expectEqualStrings("shared-try", a.slice());
    try testing.expectEqualStrings("shared-try", b.slice());
    try testing.expectEqual(@as(usize, 2), a.strongCount());
}

test "SharedString: tryUnwrap returns owned bytes when exclusive" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "exclusive");
    const result = try a.tryUnwrap(allocator);
    try testing.expect(result != null);
    const owned = result.?;
    defer allocator.free(owned);
    try testing.expectEqualStrings("exclusive", owned);
    // `a` is consumed; do not use again.
}

test "SharedString: tryUnwrap succeeds with outstanding weak" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "weakly-watched");
    const weak = a.downgrade();
    defer weak.release(allocator);

    const result = try a.tryUnwrap(allocator);
    try testing.expect(result != null);
    const owned = result.?;
    defer allocator.free(owned);
    try testing.expectEqualStrings("weakly-watched", owned);
    // Weak upgrade must now fail — content is dead.
    try testing.expect(weak.upgrade(allocator) == null);
}

test "SharedString: releaseUnwrap returns null when shared" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "shared-release");
    const b = a.retain();
    defer b.release(allocator);

    const result = try a.releaseUnwrap(allocator);
    try testing.expect(result == null);
    // `a`'s strong ref was consumed; `b` still holds one.
    try testing.expectEqual(@as(usize, 1), b.strongCount());
    try testing.expectEqualStrings("shared-release", b.slice());
}

test "SharedString: releaseUnwrap returns owned bytes when last strong" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const a = try SharedString.Ref.init(allocator, "last-owner");
    const result = try a.releaseUnwrap(allocator);
    try testing.expect(result != null);
    const owned = result.?;
    defer allocator.free(owned);
    try testing.expectEqualStrings("last-owner", owned);
    // `a` is consumed; do not use again.
}

test "SharedString: ManagedRef full lifecycle without explicit allocator" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var m = try SharedString.ManagedRef.init(allocator, "managed");
    defer m.release();

    try testing.expectEqualStrings("managed", m.slice());
    try testing.expectEqual(@as(usize, 7), m.len());
    try testing.expectEqual(@as(usize, 1), m.strongCount());
    try testing.expectEqual(@as(usize, 0), m.weakCount());

    const m2 = m.retain();
    defer m2.release();
    try testing.expectEqual(@as(usize, 2), m.strongCount());

    const mw = m.downgrade();
    defer mw.release();
    try testing.expectEqual(@as(usize, 1), m.weakCount());

    const upgraded = mw.upgrade() orelse return error.UpgradeFailed;
    defer upgraded.release();
    try testing.expectEqualStrings("managed", upgraded.slice());

    // mutate without allocator.
    try m.mutate("mutated");
    try testing.expectEqualStrings("mutated", m.slice());
}

test "SharedString: ManagedRef initCapacity and mutate" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    var m = try SharedString.ManagedRef.initCapacity(allocator, "hi", 32);
    defer m.release();
    const original_ptr = m.inner.ptr;
    try m.mutate("in-place thirty-two byte string!");
    try testing.expectEqual(original_ptr, m.inner.ptr);
    try testing.expectEqualStrings("in-place thirty-two byte string!", m.slice());
}

test "SharedString: ManagedRef tryUnwrap / releaseUnwrap" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    {
        const m = try SharedString.ManagedRef.init(allocator, "try-me");
        const result = try m.tryUnwrap();
        try testing.expect(result != null);
        defer allocator.free(result.?);
        try testing.expectEqualStrings("try-me", result.?);
    }

    {
        const m = try SharedString.ManagedRef.init(allocator, "rel-me");
        const result = try m.releaseUnwrap();
        try testing.expect(result != null);
        defer allocator.free(result.?);
        try testing.expectEqualStrings("rel-me", result.?);
    }

    {
        const m = try SharedString.ManagedRef.init(allocator, "shared-try");
        defer m.release();
        const other = m.retain();
        defer other.release();
        try testing.expect(try m.tryUnwrap() == null);
    }
}

test "SharedString: ManagedWeak full lifecycle" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const m = try SharedString.ManagedRef.init(allocator, "managed-weak");
    const mw = m.downgrade();

    try testing.expectEqual(@as(usize, 1), mw.strongCount());
    try testing.expectEqual(@as(usize, 1), mw.weakCount());

    const upgraded = mw.upgrade() orelse return error.UpgradeFailed;
    upgraded.release();

    m.release();
    try testing.expectEqual(@as(usize, 0), mw.strongCount());
    try testing.expect(mw.upgrade() == null);
    mw.release();
}

test "SharedString: Weak.upgrade accepts allocator parameter" {
    // Compile-time signature parity check with zigrc.Weak.upgrade(alloc).
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer testing.expectEqual(.ok, gpa.deinit()) catch {};
    const allocator = gpa.allocator();

    const strong = try SharedString.Ref.init(allocator, "sig");
    defer strong.release(allocator);
    const weak = strong.downgrade();
    defer weak.release(allocator);

    // Passing the allocator to upgrade must type-check and return a Ref.
    const upgraded = weak.upgrade(allocator) orelse return error.UpgradeFailed;
    upgraded.release(allocator);
}
