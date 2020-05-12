load("@io_bazel_rules_go//go:def.bzl", "go_context", "go_rule")
load(
    "@io_bazel_rules_go//go/private:providers.bzl",
    "GoLibrary",
    "INFERRED_PATH",
)
load(
    "@io_bazel_rules_go//go/private:mode.bzl",
    "LINKMODE_C_ARCHIVE",
)
load(
    "@io_bazel_rules_go//go:def.bzl",
    "go_binary",
    "go_library",
)

main_tpl = """
// Generated file. DO NOT EDIT.

package main
import (
    "unsafe"
    target "%s"
)
// #include <stdint.h>
import "C"
//export LLVMFuzzerTestOneInput
func LLVMFuzzerTestOneInput(data *C.char, size C.size_t) C.int {
	s := make([]byte, size)
	copy(s, (*[1 << 30]byte)(unsafe.Pointer(data))[:size:size])
	target.%s(s)
	return 0
}
func main() {
}
"""

main_tpl_with_diff = """
// Generated file. DO NOT EDIT.

package main
import (
    "unsafe"
    target "%s"
)
// #include <stdint.h>
// #include "fuzz/cc_python/cgo.h"
import "C"
//export GO_LLVMFuzzerTestOneInput
func GO_LLVMFuzzerTestOneInput(data *C.char, size C.size_t) C.GoFuzzResult {
	s := make([]byte, size)
	copy(s, (*[1 << 30]byte)(unsafe.Pointer(data))[:size:size])
	result, ok := target.%s(s)
	if !ok || len(result) == 0 {
	    return nil
	}
	return C.LoadGoFuzzResult((*C.uchar)(unsafe.Pointer(&result[0])), C.size_t(len(result)))
}

func main() {
}
"""

cc_diff_fuzz_tpl = """
#include "fuzz/cc_python/differential.h"
#include "fuzz/cc_python/go.h"
#include "fuzz/cc_python/python.h"

std::unique_ptr<fuzzing::Differential> differential = nullptr;

extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv) {
  differential = std::make_unique<fuzzing::Differential>();

  differential->AddModule(std::make_shared<fuzzing::Go>("prysm"));
  differential->AddModule(std::make_shared<fuzzing::Python>(
      "pyspec", (*argv)[0], "%s" /*scriptPath*/, true /*disableBls*/));

  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(uint8_t* data, size_t size) {
  differential->Run(data, size);

  return 0;
}
"""

def _gen_fuzz_main_impl(ctx):
    if ctx.var.get("gotags") != "libfuzzer":
        fail("gotags must be set to libfuzzer. Use --config=fuzz or --config=fuzzit.")
    if ctx.var.get("gc_goopts") != "-d=libfuzzer":
        fail("gc_goopts must be set to -d=libfuzzer. Use --config=fuzz or --config=fuzzit.")

    pkg = ctx.attr.target_pkg
    func = ctx.attr.func

    output_file_name = ctx.label.name + "_main.fuzz.go"
    output_file = ctx.actions.declare_file(output_file_name)

    # if using python diff
    if True:
        ctx.actions.write(output_file, main_tpl_with_diff % (pkg, func))
    else:
        ctx.actions.write(output_file, main_tpl % (pkg, func))
    return [DefaultInfo(files = depset([output_file]))]

gen_fuzz_main = rule(
    implementation = _gen_fuzz_main_impl,
    attrs = {
        "target_pkg": attr.string(mandatory = True),
        "func": attr.string(mandatory = True),
        "python": attr.string(),  # TODO: Should be a file...
    },
)

def _gen_fuzz_cc_diff_impl(ctx):
    if ctx.var.get("gotags") != "libfuzzer":
        fail("gotags must be set to libfuzzer. Use --config=fuzz or --config=fuzzit.")
    if ctx.var.get("gc_goopts") != "-d=libfuzzer":
        fail("gc_goopts must be set to -d=libfuzzer. Use --config=fuzz or --config=fuzzit.")

    output_file_name = ctx.label.name + "_diff_fuzz_main.cc"
    output_file = ctx.actions.declare_file(output_file_name)

    script_path = "fuzz/block_fuzz.py"  # TODO

    ctx.actions.write(output_file, cc_diff_fuzz_tpl % (script_path))
    return [DefaultInfo(files = depset([output_file]))]

gen_fuzz_cc_diff = rule(
    implementation = _gen_fuzz_cc_diff_impl,
    attrs = {
        "python": attr.string(),  # TODO: Should be a file...
    },
)

def go_fuzz_test(
        name,
        corpus,
        corpus_path,
        importpath,
        func = "Fuzz",
        repository = "",
        input_size = 0,
        size = "medium",
        tags = [],
        python = None,
        **kwargs):
    go_library(
        name = name + "_lib_with_fuzzer",
        tags = ["manual"] + tags,
        visibility = ["//visibility:private"],
        testonly = 1,
        importpath = importpath,
        gc_goopts = ["-d=libfuzzer"],
        **kwargs
    )
    gen_fuzz_main(
        name = name + "_libfuzz_main",
        target_pkg = importpath,
        func = func,
        tags = ["manual"] + tags,
        testonly = 1,
        visibility = ["//visibility:private"],
    )
    binary_cdeps = None
    if python:
        binary_cdeps = [
            "//fuzz/cc_python:go",
        ]

    go_binary(
        name = name + "_binary",
        srcs = [name + "_libfuzz_main"],
        deps = [name + "_lib_with_fuzzer"],
        linkmode = LINKMODE_C_ARCHIVE,
        cgo = True,
        tags = ["manual"] + tags,
        visibility = ["//visibility:private"],
        gc_goopts = ["-d=libfuzzer"],
        clinkopts = ["-Wl,--unresolved-symbols=ignore-all"],
        cdeps = binary_cdeps,
        testonly = 1,
    )

    gen_fuzz_cc_diff(
        name = name + "_libfuzz_diff_cc_main",
        python = python,
    )

    native.cc_library(
        name = name + "_diff_fuzz_main_cc",
        srcs = [
            name + "_libfuzz_diff_cc_main",
            name + "_binary",
        ],
        deps = [
            "//fuzz/cc_python:differential",
            "//fuzz/cc_python:go",
            "//fuzz/cc_python:python",
        ],
        testonly = 1,
        linkopts = ["-fsanitize=fuzzer,address"],
        copts = ["-fsanitize=fuzzer,address"],
    )

    native.genrule(
        name = name,
        outs = [name + ".a"],
        srcs = [":" + name + "_binary"],
        cmd = "cp $< $@",
        visibility = kwargs.get("visibility"),
        tags = ["manual"] + tags,
        testonly = 1,
    )

    if not (corpus.startswith("//") or corpus.startswith(":") or corpus.startswith("@")):
        corpus_name = name + "_corpus"
        corpus = native.glob([corpus + "/**"])
        native.filegroup(
            name = corpus_name,
            srcs = corpus,
        )
    else:
        corpus_name = corpus

    additional_args = []
    if input_size > 0:
        additional_args += ["-max_len=%s" % input_size]

    native.cc_test(
        name = name + "_with_libfuzzer",
        linkopts = [
            "-fsanitize=fuzzer,address",
        ],
        copts = ["-fsanitize=fuzzer,address"],
        linkstatic = 1,
        testonly = 1,
        srcs = [name + "_diff_fuzz_main_cc", name],
        deps = [
            "@herumi_bls_eth_go_binary//:lib",
            "//fuzz/cc_python:differential",
            "//fuzz/cc_python:go",
            "//fuzz/cc_python:python",
        ],
        tags = ["manual", "fuzzer"] + tags,
        args = [
            corpus_path,
            "-print_final_stats=1",
            "-use_value_profile=1",
            "-max_total_time=3540",  # One minute early of 3600.
        ] + additional_args,
        data = [corpus_name],
        timeout = "eternal",
    )
