/// SharedString — heap-allocated, reference-counted, copy-on-write immutable string.
///
/// ## Design
///
/// Fused single allocation: the SharedString header and string bytes live in
/// one contiguous allocation, eliminating the two-allocation cost of the naive
/// design and improving cache locality.
///
///   [ SharedString header | ... string bytes (cap) ... ]
///   ^-- aligned to @alignOf(SharedString)
///
/// ## Ownership model
///
///   Ref.init(allocator, str)    → new allocation, strong = 1, weak = 1 (ghost).
///   ref.retain()                → bumps strong count, returns second handle.
///   ref.release(allocator)      → decrements strong count; zeros bytes on
///                                 hitting 0; frees allocation when weak
///                                 count reaches 0.
///   ref.downgrade()             → returns a Weak handle (bumps weak count).
///   weak.upgrade(allocator)     → strong Ref if still alive, null otherwise.
///   ref.mutate(allocator, new)  → in-place if exclusive and fits in cap;
///                                 CoW otherwise.
///
/// ## Weak references
///
///   Two counters cooperate:
///     strong_count — owning references.
///     weak_count   — user Weak handles, plus one ghost ref held collectively
///                    by all strong Refs while strong_count > 0.  Matching the
///                    Rust/zigrc Arc convention.
///
///   When strong_count reaches zero the string bytes are security-zeroed
///   (content is dead; no Ref can access them any more).  The allocation
///   itself is only freed when weak_count reaches zero, which cannot happen
///   while strong_count > 0 because the ghost ref is still counted.
///
///   Weak handles hold a raw pointer to the SharedString header.  They
///   cannot access the string bytes directly — only via a successful
///   upgrade().
///
/// ## Copy-on-write
///
///   `mutate()` is safe to call on any Ref:
///   - Exclusive owner (strong_count == 1, no outstanding Weak) and new
///     content fits in `cap`:
///     overwrite bytes in-place, update len, zero the unused tail.
///   - Shared, Weak refs outstanding, or new content exceeds cap:
///     allocate a new header+bytes, then release the old ref.
///
///   Exclusivity is implied by strong_count == 1 observed by the owning
///   thread: no other thread can legitimately obtain a strong Ref to this
///   allocation without already holding one (which would make the count ≥ 2).
///   Outstanding Weak handles force the CoW path because a concurrent
///   Weak.upgrade() could otherwise observe mid-mutation bytes.  A data race
///   on the Ref *struct* itself is Undefined Behavior and cannot be papered
///   over by the payload; we therefore do not attempt to synchronise
///   concurrent mutate/retain on the *same* Ref value.
///
/// ## Thread safety
///
///   Count ops use the standard Arc fence protocol (std.atomic §RefCount):
///   monotonic on increment, release on decrement, acquire fence on final
///   drop.  Bytes are immutable between a retain() and the next mutate() on
///   the *exclusive* path.  Different Refs to the same allocation never take
///   the in-place path (count ≥ 2), so the bytes they observe are stable for
///   the lifetime of their handle.
///
/// ## Security
///
///   When strong_count reaches zero the string bytes (full `cap` plus the
///   terminator slot) are zeroed, preventing residual data in heap free lists
///   once the allocation is ultimately freed.  mutate() also zeroes the
///   unused tail after an in-place shrink, so the invariant "bytes in
///   [len..cap] are zero" holds at all observable points.
///
/// ## Size limits
///
///   `len` and `cap` are `u32`, capping any single SharedString at 4 GiB.
///   This saves 8 bytes of header overhead on 64-bit systems versus `usize`
///   and is more than sufficient for every expected use case.
///
/// ## Allocator choice
///
///   Pass std.heap.smp_allocator for long-lived, shared strings in production.
///   smp_allocator is a thread-safe TLSF allocator with O(1) alloc/free and
///   bounded fragmentation (~25% worst case), making a custom bucket pool
///   unnecessary.  Use std.testing.allocator (or DebugAllocator) in tests.
const std = @import("std");

/// Returned by init/mutate when the requested content exceeds the u32
/// capacity limit (4 GiB - 1).  See the "Size limits" section in the
/// SharedString doc comment.
pub const Error = std.mem.Allocator.Error || error{StringTooLong};

const MAX_LEN: usize = std.math.maxInt(u32);

/// Manages shared string data with ownership and lifetime control; ensures safe access across contexts.
pub const SharedString = struct {
    strong_count: std.atomic.Value(u32),
    weak_count: std.atomic.Value(u32),
    len: u32,
    /// Allocated byte capacity for the string region (>= len always).
    /// Tracks the original allocation size so the backing memory can be
    /// freed correctly and so mutate() can reuse capacity after an in-place
    /// shrink.
    cap: u32,
    // String bytes immediately follow this struct in the same allocation.
    // Access via bytesPtr().
    //
    // Invariants:
    //   - bytes in [len..cap] are zero
    //   - the backing allocation is always (cap + 1) bytes long so that
    //     byte[len] is a guaranteed NUL terminator for sliceZ() / C interop
    //   - len <= cap <= MAX_LEN (= u32 max)

    comptime {
        // bytesPtr() assumes the payload begins exactly at @sizeOf(SharedString)
        // with no trailing padding.  If a future field introduces padding, this
        // assertion will fail loudly at compile time.
        std.debug.assert(@sizeOf(SharedString) == 4 * @sizeOf(u32));
        std.debug.assert(@alignOf(SharedString) == @alignOf(u32));
    }

    // -----------------------------------------------------------------------
    // Internal: byte access
    // -----------------------------------------------------------------------

    pub fn bytesPtr(self: *const SharedString) [*]u8 {
        return @as([*]u8, @ptrFromInt(@intFromPtr(self) + @sizeOf(SharedString)));
    }

    // -----------------------------------------------------------------------
    // Internal: allocation / deallocation
    // -----------------------------------------------------------------------

    fn create(allocator: std.mem.Allocator, str: []const u8, min_cap: usize) Error!*SharedString {
        const want_cap = @max(str.len, min_cap);
        if (want_cap > MAX_LEN) return error.StringTooLong;
        // +1 for the guaranteed NUL terminator at byte[len].
        const total = @sizeOf(SharedString) + want_cap + 1;
        const align_of = comptime std.mem.Alignment.fromByteUnits(@alignOf(SharedString));
        const raw = try allocator.alignedAlloc(u8, align_of, total);
        const self: *SharedString = @ptrCast(raw.ptr);
        self.strong_count = std.atomic.Value(u32).init(1);
        // Start weak_count at 1 — the ghost ref collectively owned by all
        // strong Refs.  Released when the last strong Ref is dropped.
        self.weak_count = std.atomic.Value(u32).init(1);
        self.len = @intCast(str.len);
        self.cap = @intCast(want_cap);
        const bp = self.bytesPtr();
        if (str.len > 0) @memcpy(bp[0..str.len], str);
        // Zero [len..cap] to establish the invariant, and byte[cap] as the
        // final terminator slot.  (byte[len] is covered by this memset as
        // long as len < cap; if len == cap, byte[cap] covers it.)
        @memset(bp[str.len .. want_cap + 1], 0);
        return self;
    }

    fn deallocate(self: *SharedString, allocator: std.mem.Allocator) void {
        const payload_len: usize = @as(usize, self.cap) + 1;
        const total = @sizeOf(SharedString) + payload_len;
        const raw: [*]align(@alignOf(SharedString)) u8 = @ptrCast(self);
        allocator.free(raw[0..total]);
    }

    /// Security zero: wipe the string bytes (including the terminator slot)
    /// so nothing sensitive lingers for Weak handles or in heap free lists
    /// after the last strong Ref is dropped.
    fn zeroBytes(self: *SharedString) void {
        const payload_len: usize = @as(usize, self.cap) + 1;
        @memset(self.bytesPtr()[0..payload_len], 0);
    }

    // -----------------------------------------------------------------------
    // Internal: ref-count management
    // -----------------------------------------------------------------------

    fn acquireStrong(self: *SharedString) void {
        // Monotonic: standard Arc clone ordering.  The acquire fence on the
        // final drop synchronises with all prior releases.
        _ = self.strong_count.fetchAdd(1, .monotonic);
    }

    fn acquireWeak(self: *SharedString) void {
        _ = self.weak_count.fetchAdd(1, .monotonic);
    }

    /// Decrement strong count with acquire/release fence protocol
    /// (std.atomic §RefCount).  When the last strong Ref is dropped the
    /// bytes are zeroed and the ghost weak ref is released — the allocation
    /// is freed only once the last Weak is gone.
    fn releaseStrong(self: *SharedString, allocator: std.mem.Allocator) void {
        if (self.strong_count.fetchSub(1, .release) != 1) return;
        // Acquire fence: synchronise with every prior release so we see
        // all writes from all previous decrements before acting on zero.
        _ = self.strong_count.load(.acquire);
        // Security zero: content is dead, but the header (and therefore
        // the Weak handles that still reference it) can live on.
        self.zeroBytes();
        // Drop the ghost weak ref now that no strong Ref exists.
        self.releaseWeak(allocator);
    }

    fn releaseWeak(self: *SharedString, allocator: std.mem.Allocator) void {
        if (self.weak_count.fetchSub(1, .release) != 1) return;
        _ = self.weak_count.load(.acquire);
        self.deallocate(allocator);
    }

    /// Attempt to bump strong_count from N>0 to N+1.  Used by Weak.upgrade().
    /// Returns true on success.
    fn tryAcquireStrong(self: *SharedString) bool {
        var prev = self.strong_count.load(.monotonic);
        while (true) {
            if (prev == 0) return false;
            if (self.strong_count.cmpxchgWeak(prev, prev + 1, .acquire, .monotonic)) |observed| {
                prev = observed;
                std.atomic.spinLoopHint();
                continue;
            }
            return true;
        }
    }

    fn strongCountRaw(self: *const SharedString) usize {
        return @as(*const std.atomic.Value(u32), &self.strong_count).load(.acquire);
    }

    /// User-visible weak count: raw weak_count minus the ghost ref held
    /// collectively by all strong Refs while strong_count > 0.
    fn weakCountUser(self: *const SharedString) usize {
        const raw = @as(*const std.atomic.Value(u32), &self.weak_count).load(.acquire);
        if (@as(*const std.atomic.Value(u32), &self.strong_count).load(.acquire) > 0) {
            return raw - 1;
        }
        return raw;
    }

    // -----------------------------------------------------------------------
    // Public: byte access
    // -----------------------------------------------------------------------

    /// The immutable string contents.  Valid as long as any strong Ref is alive.
    pub fn slice(self: *const SharedString) []const u8 {
        return self.bytesPtr()[0..self.len];
    }

    /// The immutable string contents as a NUL-terminated slice, suitable
    /// for passing directly to C APIs.  The byte at `[len]` is guaranteed
    /// to be `0` at all observable times; this is maintained by `create()`
    /// (tail zero) and `mutate()` (re-zero on every write).
    pub fn sliceZ(self: *const SharedString) [:0]const u8 {
        return self.bytesPtr()[0..self.len :0];
    }

    // -----------------------------------------------------------------------
    // Ref — the public owner handle
    // -----------------------------------------------------------------------

    /// A reference-counted handle to a SharedString.
    /// Value-copyable only via `retain()`; call `release(allocator)` exactly once.
    pub const Ref = struct {
        ptr: *SharedString,

        /// Allocate a new SharedString from `str` and return the first Ref
        /// (strong_count = 1, weak_count = 1 ghost).
        pub fn init(allocator: std.mem.Allocator, str: []const u8) Error!Ref {
            return .{ .ptr = try SharedString.create(allocator, str, 0) };
        }

        /// Allocate a new SharedString from `str` with at least `min_capacity`
        /// bytes of capacity reserved.  Use this when you know the string will
        /// grow shortly after creation to avoid an immediate CoW realloc.
        pub fn initCapacity(
            allocator: std.mem.Allocator,
            str: []const u8,
            min_capacity: usize,
        ) Error!Ref {
            return .{ .ptr = try SharedString.create(allocator, str, min_capacity) };
        }

        /// Increment the strong count and return a second handle to the same
        /// allocation.  Both handles must eventually be passed to `release`.
        pub fn retain(self: Ref) Ref {
            self.ptr.acquireStrong();
            return .{ .ptr = self.ptr };
        }

        /// Decrement the strong count.  The string bytes are security-zeroed
        /// when the count reaches zero; the allocation itself is freed only
        /// once the last Weak handle is also released.  Do not use this Ref
        /// after calling release.
        pub fn release(self: Ref, allocator: std.mem.Allocator) void {
            self.ptr.releaseStrong(allocator);
        }

        /// Decrement the strong count and, if we were the last strong owner,
        /// return an owned, heap-duped copy of the string bytes.  Returns
        /// `null` if other strong refs remain.
        ///
        /// The caller owns the returned slice and must free it with
        /// `allocator`.  This signature differs from zigrc's
        /// `Rc.releaseUnwrap()` (which returns `?T` by value) because
        /// SharedString's payload is variable-length, so extraction
        /// necessarily allocates.  The semantic contract is identical: the
        /// Ref is consumed whether a slice is returned or null.
        ///
        /// On allocator failure the refcount is left untouched and the Ref
        /// remains valid; the caller must either retry or call `release`.
        pub fn releaseUnwrap(self: Ref, allocator: std.mem.Allocator) Error!?[]u8 {
            // Allocate the dupe first so allocation failure leaves the
            // refcount untouched and the Ref still valid.
            const dup = try allocator.dupe(u8, self.ptr.slice());
            if (self.ptr.strong_count.fetchSub(1, .release) != 1) {
                allocator.free(dup);
                return null;
            }
            _ = self.ptr.strong_count.load(.acquire);
            self.ptr.zeroBytes();
            self.ptr.releaseWeak(allocator);
            return dup;
        }

        /// Return an owned, heap-duped copy of the string bytes only if this
        /// Ref is the exclusive strong owner (strong_count == 1).  Succeeds
        /// even if Weak handles are outstanding.
        ///
        /// On success the Ref is consumed and must not be used again.  On
        /// `null` (shared) the Ref is untouched.  On allocator failure the
        /// refcount is untouched and the Ref remains valid.
        ///
        /// Like `releaseUnwrap`, this returns `Error!?[]u8` rather than `?T`
        /// because SharedString's payload is variable-length.
        pub fn tryUnwrap(self: Ref, allocator: std.mem.Allocator) Error!?[]u8 {
            if (self.ptr.strong_count.load(.acquire) != 1) return null;
            // Dupe first so allocation failure leaves refcount untouched.
            const dup = try allocator.dupe(u8, self.ptr.slice());
            // Atomically transition strong 1 → 0.  Fails if a concurrent
            // Weak.upgrade() bumped strong to 2 between the load and here.
            if (self.ptr.strong_count.cmpxchgStrong(1, 0, .acquire, .monotonic) != null) {
                allocator.free(dup);
                return null;
            }
            self.ptr.zeroBytes();
            self.ptr.releaseWeak(allocator);
            return dup;
        }

        /// Produce a Weak handle to this allocation.  Increments the weak
        /// count.  The Weak handle cannot access the string bytes directly;
        /// call `upgrade()` to attempt to obtain a strong Ref.
        pub fn downgrade(self: Ref) Weak {
            self.ptr.acquireWeak();
            return .{ .ptr = self.ptr };
        }

        /// Current strong reference count.
        pub fn strongCount(self: Ref) usize {
            return self.ptr.strongCountRaw();
        }

        /// Current user-visible weak reference count (excludes the ghost
        /// ref held collectively by strong owners).
        pub fn weakCount(self: Ref) usize {
            return self.ptr.weakCountUser();
        }

        /// The string contents.  Valid as long as this Ref is alive.
        pub fn slice(self: Ref) []const u8 {
            return self.ptr.slice();
        }

        /// NUL-terminated view of the contents for C interop.
        /// Valid as long as this Ref is alive.
        pub fn sliceZ(self: Ref) [:0]const u8 {
            return self.ptr.sliceZ();
        }

        /// Byte-wise equality.  Two Refs that share the same underlying
        /// allocation short-circuit to true.
        pub fn eql(self: Ref, other: Ref) bool {
            if (self.ptr == other.ptr) return true;
            return std.mem.eql(u8, self.slice(), other.slice());
        }

        /// Byte-wise equality against a raw string.
        pub fn eqlSlice(self: Ref, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }

        /// Lexicographic ordering, compatible with std.sort.
        pub fn order(self: Ref, other: Ref) std.math.Order {
            if (self.ptr == other.ptr) return .eq;
            return std.mem.order(u8, self.slice(), other.slice());
        }

        /// 64-bit hash of the contents, suitable for std.HashMap /
        /// std.AutoHashMap-style containers when used via a custom Context.
        pub fn hash(self: Ref) u64 {
            return std.hash.Wyhash.hash(0, self.slice());
        }

        /// std.fmt integration: prints the string contents directly.
        /// Enables `std.debug.print("{f}", .{my_ref})` and friends.
        pub fn format(self: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.slice());
        }

        /// Context type for use with `std.HashMap(Ref, V, Ref.HashContext, ...)`.
        /// Hashes and compares by string content, not pointer identity, so two
        /// separately-allocated Refs with the same bytes map to the same slot.
        pub const HashContext = struct {
            pub fn hash(_: HashContext, key: Ref) u64 {
                return key.hash();
            }
            pub fn eql(_: HashContext, a: Ref, b: Ref) bool {
                return a.eql(b);
            }
        };

        /// Byte length of the string.
        pub fn len(self: Ref) usize {
            return self.ptr.len;
        }

        /// Replace the string content.
        ///
        /// Two cases:
        ///
        ///   Case 1 — exclusive strong owner (strong_count == 1), no
        ///            outstanding Weak handles, and new content fits in
        ///            the existing `cap`:
        ///     Overwrite bytes in-place, update len, zero the unused tail.
        ///     `self.ptr` is unchanged.
        ///
        ///   Case 2 — shared owner, outstanding Weak refs, OR new content
        ///            exceeds cap:
        ///     Allocate new header+bytes.  Release the old ref (which frees
        ///     the old allocation if we were the sole owner and no Weaks
        ///     remain, otherwise leaves it alive for the other holders).
        ///     Update `self.ptr`.
        ///
        /// After mutate() returns, `self` is the sole owner of a Ref whose
        /// slice() returns new_content.
        pub fn mutate(self: *Ref, allocator: std.mem.Allocator, new_content: []const u8) Error!void {
            if (new_content.len > MAX_LEN) return error.StringTooLong;
            // Case 1: exclusive, no Weak upgrades possible, fits in capacity.
            //
            // strong_count == 1 observed by this thread implies no other
            // thread holds a strong Ref.  weak_count == 1 (just the ghost)
            // implies no user Weak exists, so no concurrent Weak.upgrade()
            // can race with our byte write.  A race on this *same* Ref
            // value from another thread would be a data race on the Ref
            // struct itself (UB), outside what this type can defend against.
            if (new_content.len <= self.ptr.cap and
                self.ptr.strong_count.load(.acquire) == 1 and
                self.ptr.weak_count.load(.acquire) == 1)
            {
                const bp = self.ptr.bytesPtr();
                const old_len = self.ptr.len;
                if (new_content.len > 0) @memcpy(bp[0..new_content.len], new_content);
                // Preserve both invariants:
                //   - bytes in [new_len..cap] are zero
                //   - byte[new_len] is the NUL terminator for sliceZ()
                // [old_len..cap] was already zero (and byte[cap] was already
                // zero as the prior terminator slot), so we only need to zero
                // the region that was previously visible: [new_len..old_len].
                // When growing within cap (new_len > old_len) the target
                // terminator position byte[new_len] was already zero by the
                // prior invariant, so no extra write is needed.
                if (new_content.len < old_len) {
                    @memset(bp[new_content.len..old_len], 0);
                }
                self.ptr.len = @intCast(new_content.len);
                return;
            }

            // Case 2: allocate new, then release old.
            // Allocate first so we never leave self in an inconsistent state
            // on allocation failure.
            const new_ptr = try SharedString.create(allocator, new_content, 0);
            const old_ptr = self.ptr;
            self.ptr = new_ptr;
            old_ptr.releaseStrong(allocator);
        }
    };

    // -----------------------------------------------------------------------
    // Weak — non-owning handle that cannot access the bytes directly
    // -----------------------------------------------------------------------

    /// A non-owning handle to a SharedString.  Holds a raw pointer to the
    /// header and keeps the allocation alive, but does not keep the content
    /// alive — once the last strong Ref is released the bytes are zeroed.
    /// Use `upgrade()` to attempt to obtain a strong Ref.
    pub const Weak = struct {
        ptr: *SharedString,

        /// Create a Weak from a strong Ref.  Increments the weak count.
        pub fn init(parent: Ref) Weak {
            parent.ptr.acquireWeak();
            return .{ .ptr = parent.ptr };
        }

        /// Increment the weak count and return a second Weak handle.
        pub fn retain(self: Weak) Weak {
            self.ptr.acquireWeak();
            return .{ .ptr = self.ptr };
        }

        /// Decrement the weak count.  The allocation is freed when the
        /// count reaches zero, which can only happen after the last strong
        /// Ref has been released (and therefore also released the ghost
        /// weak ref).
        pub fn release(self: Weak, allocator: std.mem.Allocator) void {
            self.ptr.releaseWeak(allocator);
        }

        /// Attempt to obtain a strong Ref.  Returns `null` if the last
        /// strong Ref has already been released.
        ///
        /// The `allocator` parameter is accepted for signature parity with
        /// zigrc's `Weak.upgrade(alloc)` — no allocation is actually
        /// performed, so the parameter is unused.
        pub fn upgrade(self: Weak, allocator: std.mem.Allocator) ?Ref {
            _ = allocator;
            if (self.ptr.tryAcquireStrong()) return Ref{ .ptr = self.ptr };
            return null;
        }

        /// Current strong reference count.  Returns 0 if the content is dead.
        pub fn strongCount(self: Weak) usize {
            return self.ptr.strongCountRaw();
        }

        /// Current user-visible weak reference count (excludes the ghost
        /// ref held collectively by strong owners).
        pub fn weakCount(self: Weak) usize {
            return self.ptr.weakCountUser();
        }
    };

    // -----------------------------------------------------------------------
    // ManagedRef / ManagedWeak — allocator stored in the handle
    // -----------------------------------------------------------------------

    /// A `Ref` that stores its allocator, mirroring zigrc's managed variants.
    /// All lifecycle methods drop the explicit allocator parameter.
    pub const ManagedRef = struct {
        inner: Ref,
        alloc: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, str: []const u8) Error!ManagedRef {
            return .{ .inner = try Ref.init(allocator, str), .alloc = allocator };
        }

        pub fn initCapacity(
            allocator: std.mem.Allocator,
            str: []const u8,
            min_capacity: usize,
        ) Error!ManagedRef {
            return .{
                .inner = try Ref.initCapacity(allocator, str, min_capacity),
                .alloc = allocator,
            };
        }

        pub fn retain(self: ManagedRef) ManagedRef {
            return .{ .inner = self.inner.retain(), .alloc = self.alloc };
        }

        pub fn release(self: ManagedRef) void {
            self.inner.release(self.alloc);
        }

        pub fn releaseUnwrap(self: ManagedRef) Error!?[]u8 {
            return self.inner.releaseUnwrap(self.alloc);
        }

        pub fn tryUnwrap(self: ManagedRef) Error!?[]u8 {
            return self.inner.tryUnwrap(self.alloc);
        }

        pub fn downgrade(self: ManagedRef) ManagedWeak {
            return .{ .inner = self.inner.downgrade(), .alloc = self.alloc };
        }

        pub fn strongCount(self: ManagedRef) usize {
            return self.inner.strongCount();
        }

        pub fn weakCount(self: ManagedRef) usize {
            return self.inner.weakCount();
        }

        pub fn mutate(self: *ManagedRef, new_content: []const u8) Error!void {
            return self.inner.mutate(self.alloc, new_content);
        }

        pub fn slice(self: ManagedRef) []const u8 {
            return self.inner.slice();
        }

        pub fn sliceZ(self: ManagedRef) [:0]const u8 {
            return self.inner.sliceZ();
        }

        pub fn eql(self: ManagedRef, other: ManagedRef) bool {
            return self.inner.eql(other.inner);
        }

        pub fn eqlSlice(self: ManagedRef, other: []const u8) bool {
            return self.inner.eqlSlice(other);
        }

        pub fn order(self: ManagedRef, other: ManagedRef) std.math.Order {
            return self.inner.order(other.inner);
        }

        pub fn hash(self: ManagedRef) u64 {
            return self.inner.hash();
        }

        pub fn format(self: ManagedRef, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return self.inner.format(writer);
        }

        pub fn len(self: ManagedRef) usize {
            return self.inner.len();
        }

        pub const HashContext = struct {
            pub fn hash(_: HashContext, key: ManagedRef) u64 {
                return key.hash();
            }
            pub fn eql(_: HashContext, a: ManagedRef, b: ManagedRef) bool {
                return a.eql(b);
            }
        };
    };

    /// A `Weak` that stores its allocator, mirroring zigrc's managed variants.
    pub const ManagedWeak = struct {
        inner: Weak,
        alloc: std.mem.Allocator,

        pub fn init(parent: ManagedRef) ManagedWeak {
            return .{ .inner = Weak.init(parent.inner), .alloc = parent.alloc };
        }

        pub fn retain(self: ManagedWeak) ManagedWeak {
            return .{ .inner = self.inner.retain(), .alloc = self.alloc };
        }

        pub fn release(self: ManagedWeak) void {
            self.inner.release(self.alloc);
        }

        pub fn upgrade(self: ManagedWeak) ?ManagedRef {
            if (self.inner.upgrade(self.alloc)) |ref| {
                return ManagedRef{ .inner = ref, .alloc = self.alloc };
            }
            return null;
        }

        pub fn strongCount(self: ManagedWeak) usize {
            return self.inner.strongCount();
        }

        pub fn weakCount(self: ManagedWeak) usize {
            return self.inner.weakCount();
        }
    };
};
