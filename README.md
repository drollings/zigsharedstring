# zigsharedstring

A Zig library providing `SharedString`: a fused-allocation, reference-counted, copy-on-write immutable string primitive with weak references, adapted from a custom implementation to fuse and work alongside https://github.com/Aandreba/zigrc.

## Features

- **Fused allocation**: String header and bytes live in one contiguous heap block for cache locality and reduced allocation count
- **Reference counting**: Strong and weak references with ghost-ref protocol (matching `Arc.Weak` from zigrc)
- **Copy-on-write mutations**: `mutate()` is in-place if exclusive, otherwise copies on write
- **Security zeroing**: Optional `zero_on_destroy` to overwrite secrets on final release
- **Weak references**: `Weak.upgrade()` for safe weak-to-strong promotion; `upgrade()` returns `null` if already dropped
- **Unified API**: Uses zigrc naming conventions (`retain`, `release`, `releaseUnwrap`, `downgrade`) for consistency
- **Memory efficient**: No-copy string sharing via atomic reference counting

## Quick Start

```zig
const std = @import("std");
const SharedString = @import("zigsharedstring").SharedString;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a new shared string
    var s1 = try SharedString.Ref.init(allocator, "hello");
    defer s1.release(allocator);

    // Clone the reference (no string copy)
    var s2 = s1.retain();
    defer s2.release(allocator);

    std.debug.print("{}\n", .{s1.slice()});
    std.debug.print("strong_count: {}\n", .{s1.strongCount()});

    // Create a weak reference
    const weak = s1.downgrade();
    defer weak.release(allocator);

    // Upgrade weak reference back to strong
    if (weak.upgrade(allocator)) |upgraded| {
        upgraded.release(allocator);
    }
}
```

## API Overview

### `SharedString.Ref`

Strong reference to shared immutable string.

- `init(allocator, bytes) !Ref` - allocate and initialize
- `retain() Ref` - increment strong count, return new handle
- `release(allocator)` - decrement strong count, free if last
- `releaseUnwrap(allocator) ?[]u8` - drop ref and extract bytes if last owner
- `tryUnwrap(allocator) ?[]u8` - extract bytes if exclusive (success even with weak refs outstanding)
- `downgrade() Weak` - create weak reference
- `strongCount() usize` - get current strong ref count
- `weakCount() usize` - get current weak ref count (excludes ghost)
- `slice() []const u8` - access string bytes
- `sliceZ() [:0]const u8` - null-terminated access
- `mutate(allocator, new_bytes) !void` - update string (in-place if exclusive, CoW otherwise)
- `eql(other) bool` - equality check
- `hash() u64` - compute hash for use in maps/sets

### `SharedString.Weak`

Weak reference; does not prevent deallocation.

- `init(strong_ref: Ref) Weak` - create from strong ref
- `retain() Weak` - increment weak count
- `release(allocator)` - decrement weak count
- `upgrade(allocator) ?Ref` - attempt to promote to strong ref (null if dropped)
- `strongCount() usize` - get strong ref count
- `weakCount() usize` - get weak ref count

### `SharedString.ManagedRef` / `SharedString.ManagedWeak`

Convenience wrappers that bundle the allocator with the reference:

```zig
var m = try SharedString.ManagedRef.init(allocator, "data");
defer m.release();  // no need to pass allocator
const weak = m.downgrade();
defer weak.release();
```

## Memory Model

```
strong_count = 0  →  string bytes are zeroed; allocation remains until weak_count = 0
strong_count > 0  →  ghost weak ref kept; bytes accessible via Ref
weak_count = 0    →  allocation freed
```

When the last strong reference is released:
1. String bytes are security-zeroed (all content becomes inaccessible)
2. The ghost weak reference is released
3. If no user Weak references exist (weak_count reaches 1 → 0), allocation is freed
4. Any outstanding Weak refs still point to the freed header but `upgrade()` returns null

## Testing

```bash
zig build test
```

All tests use `std.testing.allocator` (leak detection) and are deterministic.

## Integration with zigrc

`SharedString` is designed to coexist with `zigrc`'s `Rc`/`Arc` primitives:

- Both use the same reference-counting vocabulary: `retain`, `release`, `downgrade`, `strongCount`, `weakCount`
- Both implement the ghost-weak pattern for safe lifetime management
- Both support weak references with `upgrade()` semantics
- `SharedString.Ref` is single-threaded; `Arc<SharedString.Ref>` gives you thread-safe shared strings

## Design Philosophy

### Why zigrc and zigsharedstring are separate

This design follows a **layered architecture**:

- **zigrc** (`Arc(T)`, `Rc(T)`): A generic reference-counting primitive with zero dependencies. It proves correct atomic ordering, secure zeroing via `SecureArc`, and layout assertions-then stops.

- **zigsharedstring** (`SharedString`): Demonstrates how real-world types apply zigrc's patterns. It handles variable-length payloads, copy-on-write mutations, NUL-terminated slices, and security zeroing.

- **Applications** (monorepo, etc.): Compose proven pieces into domain-specific solutions without dragging in unnecessary infrastructure.

### Proof of Concept

Zigrc is generic (`Arc(T)` for any `T`). SharedString is a specific, *complex* type:
- Variable-length payload (bytes live right after the header)
- Copy-on-write semantics (can mutate in-place or allocate new)
- Security zeroing (overwrite bytes when strong count hits zero)
- NUL-terminated slices (guaranteed byte at `[len]`)
- Three public methods (`slice`, `sliceZ`, `mutate`)

SharedString implements the identical two-counter ghost-weak protocol as Arc.  Now you can write `Arc<SharedString.Ref>` for thread-safe shared strings.  The semantics compose correctly: the Arc's atomic counters protect the SharedString's pointer, the SharedString's counters manage the bytes.  A developer sees the same API everywhere: identical semantics, identical atomic orderings, identical security guarantees.

## License

MIT License. See LICENSE for details.
