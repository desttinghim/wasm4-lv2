const std = @import("std");
const ReplaceStep = @import("tools/Replace.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // TODO: make build use platform lib extension
    const lib_ext = ".so";
    const replace = ReplaceStep.create(b, .{
        .source_path = .{ .path = "manifest.ttl.in" },
        .output_name = "manifest.ttl",
        .replacements = &[_]ReplaceStep.Replacement{
            .{ .search = "@LIB_EXT@", .replacement = lib_ext },
        },
    });

    const lib = b.addSharedLibrary("amp", "src/main.zig", .unversioned);
    lib.step.dependOn(&replace.step);
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.addIncludePath("deps/lv2/include");
    lib.force_pic = true;
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
