const std = @import("std");
const ReplaceStep = @import("tools/Replace.zig");

const manifest = std.build.FileSource{ .path = "manifest.ttl.in" };
const manifest_include = std.build.FileSource{ .path = "wasm4.ttl" };

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    // Create bundle directory
    const bundle_dir = std.build.InstallDir{ .custom = "wasm4.lv2" };

    // Add manifest file to bundle
    const install_manifest_inc = b.addInstallFileWithDir(manifest_include, bundle_dir, "wasm4.ttl");

    const lib = b.addSharedLibrary("wasm4", "src/main.zig", .unversioned);
    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.linkLibC();
    lib.addIncludePath("deps/lv2/include");
    lib.addCSourceFile("src/apu.c", &.{});
    lib.addIncludePath("src/");
    lib.force_pic = true;
    lib.install();

    const copy_lib = b.addInstallFileWithDir(lib.getOutputLibSource(), bundle_dir, lib.out_filename);
    copy_lib.step.dependOn(&lib.install_step.?.step);

    // Build manifest with the library name
    const replace = ReplaceStep.create(b, .{
        .source_path = .{ .path = "manifest.ttl.in" },
        .output_name = "manifest.ttl",
        .output_dir = bundle_dir,
        .replacements = &[_]ReplaceStep.Replacement{
            .{ .search = "@LIB_NAME@", .replacement = lib.out_filename },
        },
    });

    const bundle_step = b.step("bundle", "Create lv2 bundle");
    bundle_step.dependOn(&replace.step);
    bundle_step.dependOn(&install_manifest_inc.step);
    bundle_step.dependOn(&copy_lib.step);

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
