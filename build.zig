/// Never native: the exes are the same whichever machine builds them.
const arches = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .x86 };

pub fn build(b: *std.Build) void {
    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
        },
    }).module("std");

    const host_arch = b.graph.host.result.cpu.arch;
    if (std.mem.findScalar(std.Target.Cpu.Arch, &arches, host_arch) == null) std.debug.panic(
        "winbin doesn't build for this host's arch '{t}', use install-ARCH",
        .{host_arch},
    );

    const version_file = b.addWriteFiles().add("version-release", calendarVersion(b));
    const deps: Deps = .{
        .version_file = version_file,
        .patched_std = patched_std,
        .exelink = b.dependency("exelink", .{}),
        .wintrace = b.dependency("wintrace", .{}).module("wintrace"),
    };

    const release_step = b.step("release", "Test, and put a zip for each arch in zig-out, with zig-out/version-release");
    release_step.dependOn(&b.addInstallFile(version_file, "version-release").step);
    const zip_exe = b.dependency("zip", .{ .target = b.graph.host, .optimize = .debug }).artifact("zip");

    const run_step = b.step("run", "Run the exe for this machine's arch");
    var host_exe: ?*std.Build.Step.Compile = null;
    for (arches) |arch| {
        // The only build configuration, there's no debug/release split. A trace needs
        // unwind tables to walk the stack, and an unstripped exe to have a PDB identity to
        // match it to its PDB. wintrace doesn't support x86, so that gains nothing there.
        const traces = arch != .x86;
        const exe = b.addExecutable(.{
            .name = "winbin",
            .root_module = createModule(b, deps, arch, "src/main.zig", .{
                .optimize = .safe,
                .strip = !traces,
                .unwind_tables = if (traces) null else .none,
                .omit_frame_pointer = true,
            }),
        });

        // zig-out/bin/ARCH/winbin.exe, or zig-out/bin/winbin.exe for `install`
        const install_arch = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("bin/{t}", .{arch}) } },
        });
        b.step(b.fmt("install-{t}", .{arch}), b.fmt("Install the {t} exe to zig-out/bin/{t}", .{ arch, arch }))
            .dependOn(&install_arch.step);

        // what install.ps1 downloads
        const zip_files = b.addWriteFiles();
        _ = zip_files.addCopyFile(exe.getEmittedBin(), "winbin.exe");
        if (traces) _ = zip_files.addCopyFile(exe.getEmittedPdb(), "winbin.pdb");
        const zip = b.addRunArtifact(zip_exe);
        const zip_file = zip.addOutputFileArg("winbin.zip");
        zip.addArg("winbin.exe");
        if (traces) zip.addArg("winbin.pdb");
        zip.setCwd(zip_files.getDirectory());
        release_step.dependOn(&b.addInstallFile(zip_file, b.fmt("winbin-{t}.zip", .{arch})).step);

        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{t}", .{arch}), b.fmt("Run the {t} exe", .{arch})).dependOn(&run.step);

        if (arch == host_arch) {
            host_exe = exe;
            b.installArtifact(exe);
            run_step.dependOn(&run.step);
        }
    }

    const test_step = b.step("test", "Run the tests");
    release_step.dependOn(test_step);
    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // the exe for this machine's arch, run for real against a local server
    addE2eTests(b, test_step, "e2e", host_exe.?);

    const leak_check_exe = b.addExecutable(.{
        .name = "winbin-leak-check",
        .root_module = createModule(b, deps, host_arch, "src/main_leak_check.zig", .{ .optimize = .debug }),
    });
    addE2eTests(b, test_step, "e2e-leak-check", leak_check_exe);

    if (host_arch != .x86) {
        const crash_paths = b.addOptions();
        // Copied somewhere without its PDB, like a shipped exe.
        const release = b.addExecutable(.{
            .name = "crash-test",
            .root_module = createModule(b, deps, host_arch, "src/crash_test_main.zig", .{ .optimize = .safe }),
        });
        crash_paths.addOptionPath("release", b.addWriteFiles().addCopyFile(release.getEmittedBin(), "crash-test.exe"));
        const debug = b.addExecutable(.{
            .name = "crash-test",
            .root_module = createModule(b, deps, host_arch, "src/crash_test_main.zig", .{ .optimize = .debug }),
        });
        crash_paths.addOptionPath("debug", debug.getEmittedBin());
        const crash_module = b.createModule(.{
            .root_source_file = b.path("test/crash.zig"),
            .target = b.graph.host,
        });
        crash_module.addOptions("paths", crash_paths);
        const crash_tests = b.addTest(.{ .name = "crash", .root_module = crash_module });
        test_step.dependOn(&b.addRunArtifact(crash_tests).step);
    }
}

/// Today, in UTC: vYYYY_MM_DD.
fn calendarVersion(b: *std.Build) []const u8 {
    const now: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.Io.Clock.real.now(b.graph.io).toSeconds()) };
    const year_day = now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return b.fmt("v{d}_{d:0>2}_{d:0>2}", .{ year_day.year, @backingInt(month_day.month), month_day.day_index + 1 });
}

const Deps = struct {
    version_file: std.Build.LazyPath,
    patched_std: *std.Build.Module,
    exelink: *std.Build.Dependency,
    wintrace: *std.Build.Module,
};

const ModuleOptions = struct {
    optimize: std.builtin.OptimizeMode,
    strip: ?bool = null,
    unwind_tables: ?std.builtin.UnwindTables = null,
    omit_frame_pointer: ?bool = null,
};

fn createModule(b: *std.Build, deps: Deps, arch: std.Target.Cpu.Arch, root: []const u8, options: ModuleOptions) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu }),
        .optimize = options.optimize,
        .strip = options.strip,
        .single_threaded = true,
        .unwind_tables = options.unwind_tables,
        .stack_protector = false,
        .omit_frame_pointer = options.omit_frame_pointer,
        .imports = &.{
            .{ .name = "std", .module = deps.patched_std },
        },
    });
    if (arch != .x86) module.addImport("wintrace", deps.wintrace);
    module.addAnonymousImport("version", .{ .root_source_file = deps.version_file });
    module.addAnonymousImport("exelink_template", .{
        .root_source_file = deps.exelink.namedLazyPath(b.fmt("template-{t}", .{arch})),
    });
    return module;
}

fn addE2eTests(b: *std.Build, test_step: *std.Build.Step, name: []const u8, exe: *std.Build.Step.Compile) void {
    const paths = b.addOptions();
    paths.addOptionPath("winbin", exe.getEmittedBin());
    const module = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = b.graph.host,
    });
    module.addOptions("paths", paths);
    const tests = b.addTest(.{ .name = name, .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const std = @import("std");
