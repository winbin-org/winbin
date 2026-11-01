//! `zig build test`'s unit tests, for what doesn't touch the disk or the network. What
//! does is in test/e2e.zig.

test {
    _ = @import("json.zig");
    _ = @import("main.zig");
    _ = @import("manifest.zig");
    _ = @import("record.zig");
}
