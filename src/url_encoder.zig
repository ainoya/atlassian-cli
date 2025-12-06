const std = @import("std");

/// URL encode a string
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len * 3);
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (isUnreserved(c)) {
            try result.append(allocator, c);
        } else {
            // Encode as %XX
            try result.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try result.append(allocator, hex[c >> 4]);
            try result.append(allocator, hex[c & 0x0F]);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Check if character is unreserved (should not be encoded)
/// Unreserved characters: A-Z a-z 0-9 - _ . ~
fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or
        c == '_' or
        c == '.' or
        c == '~';
}

test "url encode simple string" {
    const allocator = std.testing.allocator;
    const input = "hello world";
    const encoded = try urlEncode(allocator, input);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world", encoded);
}

test "url encode japanese characters" {
    const allocator = std.testing.allocator;
    const input = "自己紹介";
    const encoded = try urlEncode(allocator, input);
    defer allocator.free(encoded);
    // Should be percent-encoded UTF-8 bytes
    try std.testing.expect(std.mem.indexOf(u8, encoded, "%") != null);
}

test "url encode special chars" {
    const allocator = std.testing.allocator;
    const input = "a=b&c=d";
    const encoded = try urlEncode(allocator, input);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%3Db%26c%3Dd", encoded);
}
