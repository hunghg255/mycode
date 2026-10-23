//! Cutting text without splitting a character: a character cut short (a
//! Vietnamese letter is 2 or 3 bytes) made myzig's text measure crash.

const std = @import("std");

/// `s` without a character cut short at its end.
pub fn whole(s: []const u8) []const u8 {
    var i = s.len;
    while (i > 0 and s.len - i < 4) {
        i -= 1;
        if (s[i] & 0xc0 == 0x80) continue;
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        return if (i + n > s.len) s[0..i] else s;
    }
    return s;
}

/// The longest start of `s` at most `max` bytes long that ends between characters.
pub fn cut(s: []const u8, max: usize) []const u8 {
    return whole(s[0..@min(s.len, max)]);
}

/// The first character of `s`, upper case when it is ASCII.
pub fn initial(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    if (n == 1) return a.dupe(u8, &.{std.ascii.toUpper(s[0])}) catch s[0..1];
    return whole(s[0..@min(s.len, n)]);
}

test "cut keeps characters whole" {
    const t = std.testing;
    try t.expectEqualStrings("ab", cut("ab\xe1\xba\xa1", 4));
    try t.expectEqualStrings("ab\xe1\xba\xa1", cut("ab\xe1\xba\xa1", 5));
    try t.expectEqualStrings("ab\xe1\xba\xa1", cut("ab\xe1\xba\xa1c", 5));
    try t.expectEqualStrings("abc", cut("abc", 10));
    try t.expectEqualStrings("a", whole("a\xc6"));
    try t.expectEqualStrings("\xe1\xbb\xa8", initial(t.allocator, "\xe1\xbb\xa8ng"));
}
