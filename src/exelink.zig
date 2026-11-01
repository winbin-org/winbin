//! Makes exelinks: small exes that run another exe, from
//! https://github.com/marler8997/exelink. A link is exelink's template with the
//! target appended to its last section, and this makes the same bytes its
//! `create` does.

/// Where the target's RVA and length in UTF-16 units go, both u32: the DOS
/// header's reserved e_res2.
const target_info = 0x28;

/// The most `target` can take of a link.
pub const max_target_bytes = 16 * 1024;

fn read32(img: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, img[offset..][0..4], .little);
}

fn write32(img: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, img[offset..][0..4], value, .little);
}

/// Writes a link in `out` that runs `target`, a path relative to the directory
/// the link is in. `out` has room for the template and `max_target_bytes`, and
/// `target` is at most `max_target_bytes` / 2 long.
pub fn create(template: []const u8, target: []const u8, out: []u8) []const u8 {
    var wide_buf: [max_target_bytes / 2]u16 = undefined;
    const wide = wide_buf[0 .. std.unicode.wtf8ToWtf16Le(&wide_buf, target) catch unreachable];
    for (wide) |*c| if (c.* == '/') {
        c.* = '\\';
    };

    const pe = read32(template, 0x3c);
    const section_count = std.mem.readInt(u16, template[pe + 6 ..][0..2], .little);
    const optional_size = std.mem.readInt(u16, template[pe + 20 ..][0..2], .little);
    const optional = pe + 24;
    const last = optional + optional_size + 40 * (@as(usize, section_count) - 1);
    const section_align = read32(template, optional + 32);
    const file_align = read32(template, optional + 36);

    const address = read32(template, last + 12);
    const virtual_size = read32(template, last + 8);
    const raw_pointer = read32(template, last + 20);
    const offset = std.mem.alignForward(u32, virtual_size, 2);
    const new_virtual_size: u32 = offset + @as(u32, @intCast(wide.len * 2));
    const new_raw_size = std.mem.alignForward(u32, new_virtual_size, file_align);

    const link = out[0 .. raw_pointer + new_raw_size];
    @memset(link, 0);
    @memcpy(link[0..template.len], template);
    @memcpy(link[raw_pointer + offset ..][0 .. wide.len * 2], std.mem.sliceAsBytes(wide));
    write32(link, last + 8, new_virtual_size);
    write32(link, last + 16, new_raw_size);
    write32(link, optional + 56, std.mem.alignForward(u32, address + new_virtual_size, section_align));
    write32(link, target_info, address + offset);
    write32(link, target_info + 4, @intCast(wide.len));
    return link;
}

const std = @import("std");
