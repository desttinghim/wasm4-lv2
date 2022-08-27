const std = @import("std");
const ReplaceStep = @import("tools/Replace.zig");

const manifest = std.build.FileSource{ .path = "manifest.ttl.in" };
const manifest_include = std.build.FileSource{ .path = "wasm4.ttl" };

pub fn build(b: *std.build.Builder) !void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    // Create bundle directory
    const bundle_dir = std.build.InstallDir{ .custom = "wasm4.lv2" };

    const version = b.version(0, 1, 0);
    const version_str = b.fmt("v{}.{}.{}", .{ version.versioned.major, version.versioned.minor, version.versioned.patch });
    const version_minor = try std.fmt.allocPrint(b.allocator, "{}", .{version.versioned.minor});
    const version_micro = try std.fmt.allocPrint(b.allocator, "{}", .{version.versioned.patch});

    const print_version = b.option(bool, "version", "logs version number to output") orelse false;
    const skip = b.option(bool, "skip", "skips building binary") orelse false;
    if (print_version) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("{s}", .{version_str});
    }
    if (!skip) {
        const lib = b.addSharedLibrary("wasm4", "src/main.zig", version);
        lib.setBuildMode(mode);
        lib.setTarget(target);
        lib.linkLibC();
        lib.addIncludePath("deps/lv2/include");
        lib.addCSourceFile("src/apu.c", &.{});
        lib.addIncludePath("src/");
        lib.force_pic = true;
        lib.install();

        const libname = try b.allocator.dupe(u8, lib.out_filename);

        const copy_lib = b.addInstallFileWithDir(lib.getOutputLibSource(), bundle_dir, libname);
        copy_lib.step.dependOn(&lib.install_step.?.step);

        // Build manifest with the library name
        const manifest_replacements = try b.allocator.alloc(ReplaceStep.Replacement, 1);
        manifest_replacements[0] = ReplaceStep.Replacement{ .search = "@LIB_NAME@", .replacement = libname };

        const replace_manifest_ttl = ReplaceStep.create(b, .{
            .source_path = .{ .path = "manifest.ttl.in" },
            .output_name = "manifest.ttl",
            .output_dir = bundle_dir,
            .replacements = manifest_replacements,
        });
        replace_manifest_ttl.step.dependOn(&copy_lib.step);

        // Add version numbers to wasm4.ttl
        const wasm4_replacements = try b.allocator.alloc(ReplaceStep.Replacement, 2);
        wasm4_replacements[0] = ReplaceStep.Replacement{ .search = "@VERSION_MINOR@", .replacement = version_minor };
        wasm4_replacements[1] = ReplaceStep.Replacement{ .search = "@VERSION_MICRO@", .replacement = version_micro };

        const replace_wasm4_ttl = ReplaceStep.create(b, .{
            .source_path = .{ .path = "wasm4.ttl.in" },
            .output_name = "wasm4.ttl",
            .output_dir = bundle_dir,
            .replacements = wasm4_replacements,
        });

        const bundle_step = b.step("bundle", "Create lv2 bundle");
        bundle_step.dependOn(&replace_manifest_ttl.step);
        bundle_step.dependOn(&replace_wasm4_ttl.step);
        bundle_step.dependOn(&copy_lib.step);
    }

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
