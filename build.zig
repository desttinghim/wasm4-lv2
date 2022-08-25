const std = @import("std");
const ReplaceStep = @import("tools/Replace.zig");

const manifest = std.build.FileSource{ .path = "manifest.ttl.in" };
const manifest_include = std.build.FileSource{ .path = "fifths.ttl" };

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // Create bundle directory
    const bundle_dir = std.build.InstallDir{ .custom = "fifths.lv2" };

    // Build manifest with correct library extension
    // TODO: make build use platform lib extension
    const lib_ext = ".so";
    const replace = ReplaceStep.create(b, .{
        .source_path = .{ .path = "manifest.ttl.in" },
        .output_name = "manifest.ttl",
        .output_dir = bundle_dir,
        .replacements = &[_]ReplaceStep.Replacement{
            .{ .search = "@LIB_EXT@", .replacement = lib_ext },
        },
    });

    // Add manifest file to bundle
    const install_manifest_inc = b.addInstallFileWithDir(manifest_include, bundle_dir, "fifths.ttl");

    const lib = b.addSharedLibrary("fifths", "src/main.zig", .unversioned);
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.addIncludePath("deps/lv2/include");
    lib.force_pic = true;
    lib.install();

    const copy_lib = b.addInstallFileWithDir(lib.getOutputLibSource(), bundle_dir, "fifths" ++ lib_ext);
    copy_lib.step.dependOn(&lib.install_step.?.step);

    const bundle_step = b.step("bundle", "Create lv2 bundle");
    bundle_step.dependOn(&replace.step);
    bundle_step.dependOn(&install_manifest_inc.step);
    bundle_step.dependOn(&copy_lib.step);

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
