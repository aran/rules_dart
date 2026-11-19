"""Dart SDK release versions and the SHA-256 checksums of what each fetches."""

visibility("//dart/...")

TOOL_VERSIONS = {
    "3.14.1": {
        "macos-arm64": "b670699f921bf307c3f2754b56349863ee9b2878661bcd446b50b90296e11311",
        "macos-x64": "3d440c968d4c1bb21c6d57eb1e3e364cea687899daef46b7cc99f07d328caaae",
        "linux-x64": "759bed01e0aeb50e1a0b0a19474ba5c80c6087ce1d37b3214e475c81a44430e8",
        "linux-arm64": "c6e5581d478ac43ecf7d7028798b1bd10aef509f5e351184c755ec7eeeb1bea9",
        "windows-x64": "fb2550f71e3408f2a69ff6ee29573f341991a927f8bc9ad0601dd3c9b19945c8",
        "windows-arm64": "aca7650ed190f87446930893fa84442d90b5039d0b7e06e21318ed0cf7ddaddb",
    },
}

# The files `dart compile exe|aot-snapshot --target-os` fetches into its
# `sdk_cache` for a cross target, by archive basename: each `CROSS_TARGETS`
# pair's `gen_snapshot_{host}_{target}`, and each target's
# `dartaotruntime_{target}`. `dart_cross_tools` fetches them instead, so the
# compile action needs no network.
CROSS_TOOL_VERSIONS = {
    "3.14.1": {
        "dartaotruntime_linux_arm": "23bf32f07994a6edfa6f7862cd2181e657d67385e2cfcb5b0a9936e11269d0c9",
        "dartaotruntime_linux_arm64": "8e5309510570275424eafccf3e5686626eeee475649a7c31844e1b391e9d4579",
        "dartaotruntime_linux_riscv64": "11d7913fd402d1306fbac7a4fac1481d7dd6d4ee33c9be14bb477b3f0a27cb6b",
        "dartaotruntime_linux_x64": "39597552b13d642c5b8661dd16b2f2cef4ca54492d125a69df9ef20a9a7bc2db",
        "gen_snapshot_linux_arm64_linux_arm": "da372f7d4091b3363f13fdf20205ace55fba4fc10d99d92e0dead8f39da16de8",
        "gen_snapshot_linux_arm64_linux_riscv64": "226564dafc1151354171e8378d510b4b81abb6d55842a18d799cc50cc6ad320d",
        "gen_snapshot_linux_arm64_linux_x64": "6892d89852c30ba63f6b03580603817a590d7e982e52371ec7c2f931971228e5",
        "gen_snapshot_linux_x64_linux_arm": "337846ae8118ff4d05f8871f1fb582f472c0e7ba1f5e0cd59066ce8b01b01b34",
        "gen_snapshot_linux_x64_linux_arm64": "2916b009305a7a3a60acb9c6a36dc27071eeaa7a47797ebbaa69442f52715219",
        "gen_snapshot_linux_x64_linux_riscv64": "14005575483ca5811fbc4f5e21c6861771dff7365e993cf90916af2760c638b1",
        "gen_snapshot_macos_arm64_linux_arm": "867897ac14b16e6dc89aa65a9bfaf5e0ab85a61981bbfaca0103ed06f1de2f9f",
        "gen_snapshot_macos_arm64_linux_arm64": "1c7b4013028e385f1a2fe8b39750b341cf021868a452994b94e6886fb21d744f",
        "gen_snapshot_macos_arm64_linux_riscv64": "84025f8b977b4c5e144506d75798e937a0e053efb24eba0fce110b12bb1c1ecc",
        "gen_snapshot_macos_arm64_linux_x64": "37f3d6bd79ebf5829cdac95a80bac4210352752d37ea33593456e51167a9aca5",
        "gen_snapshot_macos_x64_linux_arm": "e6e006fec0215be75936ca65be36aacd8e537299efe7fd3c925e1a55ea9f6ddd",
        "gen_snapshot_macos_x64_linux_arm64": "75a16982b288c84c1694d1a7a32be5620c349ec4b5aba71625553a529e773af3",
        "gen_snapshot_macos_x64_linux_riscv64": "947fc674d573519a0f1c08ce495f7bf67253d409e64856904d189495966d857f",
        "gen_snapshot_macos_x64_linux_x64": "5535a45e1f724b7a10a6fe6ad0145aaea935316d561774c9cb3127c5339a6768",
        "gen_snapshot_windows_arm64_linux_arm.exe": "4e5e6817e055bf0e27f96ec394a6e452fcbeb42277e4f91e3399f77ff333d1de",
        "gen_snapshot_windows_arm64_linux_arm64.exe": "6143087fa872d4c302992ace18b3bd3fc49b4f25a8db9ceb5b2a3f93180e198e",
        "gen_snapshot_windows_arm64_linux_riscv64.exe": "19f303f5cc9b9f122b3a1361bf6e3b6e36ae939d0c25779230167442a473052f",
        "gen_snapshot_windows_arm64_linux_x64.exe": "dff6e23dbfd608a240f33ed7efc71e8295a79f4b648b5b9123c9dc6d1d255aa0",
        "gen_snapshot_windows_x64_linux_arm.exe": "d826ddf93461def60c404bd16a36555336a8078986c1af5e7274bf24bfe86876",
        "gen_snapshot_windows_x64_linux_arm64.exe": "6eeb4ea3c44249c99eeacff224507d900d1ba2b04a07ac0a81416fe863e09375",
        "gen_snapshot_windows_x64_linux_riscv64.exe": "6a2bcba6156aadc4a559af9a8d2ef1532a985d0693208bb3cf97d5066aa69e6f",
        "gen_snapshot_windows_x64_linux_x64.exe": "59f67aaa70808c9df2e1d223001f4342ea2441d342a0323f4c17c24d1f3245b1",
    },
}

# The SHA-256 of each version's source archive, GitHub's tarball of the SDK's
# release tag (https://github.com/dart-lang/sdk/archive/refs/tags/<version>.tar.gz),
# from which `dart_kernel_source` builds the outline stripper on that SDK's own
# `pkg/kernel`.
SOURCE_VERSIONS = {
    "3.14.1": "eb16c29569bc8ebe9e88add7387cbc2d7dcfb0e0edec855b8b758575c0a7c4cc",
}
