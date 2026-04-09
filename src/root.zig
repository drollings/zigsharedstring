/// zigsharedstring — SharedString: ref-counted, CoW immutable string with weak references
///
/// A SharedString is a fused-allocation reference-counted string with:
///   - Strong and weak reference counting (ghost-ref pattern)
///   - Copy-on-write mutations (requires exclusive ownership)
///   - Unified vocabulary: retain, release, releaseUnwrap, tryUnwrap, downgrade, upgrade
///
/// API mirrors zigrc's Rc/Arc naming for consistency across reference-counting primitives.
pub const SharedString = @import("shared_string.zig").SharedString;
