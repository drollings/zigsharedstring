// Example usage of SharedString with weak references and mutations

const std = @import("std");
const SharedString = @import("root.zig").SharedString;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a shared string
    var s1 = try SharedString.Ref.init(allocator, "hello world");

    std.debug.print("Original: {s}\n", .{s1.slice()});
    std.debug.print("Strong count: {}\n", .{s1.strongCount()});

    // Clone the reference (no string copy)
    var s2 = s1.retain();
    std.debug.print("After retain: strong count = {}\n", .{s1.strongCount()});

    // Create a weak reference
    var weak = s1.downgrade();
    defer weak.release(allocator);
    std.debug.print("After downgrade: weak count = {}\n", .{s1.weakCount()});

    // Upgrade weak to strong
    if (weak.upgrade(allocator)) |upgraded| {
        defer upgraded.release(allocator);
        std.debug.print("Upgraded weak ref: {s}\n", .{upgraded.slice()});
    }

    // Mutate the string (copy-on-write because we have multiple refs)
    try s1.mutate(allocator, "goodbye world");
    std.debug.print("After mutate s1: {s}\n", .{s1.slice()});
    std.debug.print("s2 unchanged: {s}\n", .{s2.slice()});

    // Try to extract the value (fails because s2 still holds it)
    if (try s1.tryUnwrap(allocator)) |owned_bytes| {
        defer allocator.free(owned_bytes);
        std.debug.print("Extracted: {s}\n", .{owned_bytes});
    } else {
        std.debug.print("Cannot unwrap s1 (s2 still holds a ref)\n", .{});
    }

    // Release s2, then try to extract s1
    s2.release(allocator);
    if (try s1.tryUnwrap(allocator)) |owned_bytes| {
        defer allocator.free(owned_bytes);
        std.debug.print("Now extracted s1: {s}\n", .{owned_bytes});
        // s1 is consumed here; no further release needed
    } else {
        std.debug.print("Could not extract\n", .{});
        s1.release(allocator); // s1 still valid, release it
    }
}
