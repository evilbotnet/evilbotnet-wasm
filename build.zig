const std = @import("std");

pub fn build(b: *std.Build) void {
    // Static web deploy: always optimize for size, no flags needed.
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Reactor-style wasm: no _start, export-driven, keep exports alive.
    exe.entry = .disabled;
    exe.rdynamic = true;

    b.installArtifact(exe);

    // Ship the HTML host next to the wasm so zig-out/bin is directly deployable.
    b.installFile("web/index.html", "bin/index.html");
}
